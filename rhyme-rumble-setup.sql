-- Rhyme Rumble: database setup for online rooms
-- Paste all of this into Supabase: SQL Editor -> New query -> Run.
-- Safe to run again; it only creates what is missing and replaces the functions.
--
-- How it works: rooms, players and recordings live in three tables that
-- nobody can read or write directly. The game only talks to the functions
-- below, and every change needs the room code plus the player's own secret
-- token, which stays on their device. Rooms close for new turns after 7 days
-- and are deleted with their recordings after 30 days.

create table if not exists public.rr_rooms (
  code       text primary key check (code ~ '^[A-Z]{6}$'),
  state      jsonb not null,
  version    integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closes_at  timestamptz not null default now() + interval '7 days'
);

create table if not exists public.rr_players (
  code      text not null references public.rr_rooms(code) on delete cascade,
  pid       text not null,
  token     text not null,
  joined_at timestamptz not null default now(),
  primary key (code, pid)
);

create table if not exists public.rr_verse_parts (
  code       text not null references public.rr_rooms(code) on delete cascade,
  id         text not null,
  part       smallint not null,
  parts      smallint not null,
  pid        text not null,
  data       bytea not null,
  created_at timestamptz not null default now(),
  primary key (code, id, part)
);

alter table public.rr_rooms       enable row level security;
alter table public.rr_players     enable row level security;
alter table public.rr_verse_parts enable row level security;
-- No policies on purpose: direct table access is closed to everyone.
revoke all on public.rr_rooms, public.rr_players, public.rr_verse_parts from anon, authenticated;

-- is this device a player in the room?
create or replace function public.rr_is_player(p_code text, p_pid text, p_token text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rr_players where code = p_code and pid = p_pid and token = p_token);
$$;
revoke all on function public.rr_is_player(text, text, text) from public, anon, authenticated;

-- open a new room
create or replace function public.rr_create(p_code text, p_pid text, p_token text, p_state jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare r rr_rooms;
begin
  delete from rr_rooms where created_at < now() - interval '30 days';   -- tidy up old rooms
  if p_code !~ '^[A-Z]{6}$' or length(p_pid) not between 4 and 32 or length(p_token) not between 16 and 64
     or octet_length(p_state::text) > 300000 then
    return jsonb_build_object('error', 'bad_request');
  end if;
  insert into rr_rooms (code, state) values (p_code, p_state) on conflict (code) do nothing returning * into r;
  if r.code is null then return jsonb_build_object('error', 'taken'); end if;
  insert into rr_players (code, pid, token) values (p_code, p_pid, p_token);
  return jsonb_build_object('version', r.version, 'closes_at', r.closes_at);
end $$;

-- join a room (or confirm you are already in it)
create or replace function public.rr_join(p_code text, p_pid text, p_token text)
returns text language plpgsql volatile security definer set search_path = public as $$
declare r rr_rooms; t text;
begin
  select * into r from rr_rooms where code = p_code;
  if r.code is null then return 'no_room'; end if;
  select token into t from rr_players where code = p_code and pid = p_pid;
  if t is not null then return case when t = p_token then 'ok' else 'bad_token' end; end if;
  if r.closes_at < now() then return 'closed'; end if;
  if (select count(*) from rr_players where code = p_code) >= 30 then return 'full'; end if;
  if length(p_pid) not between 4 and 32 or length(p_token) not between 16 and 64 then return 'bad_request'; end if;
  insert into rr_players (code, pid, token) values (p_code, p_pid, p_token);
  return 'ok';
end $$;

-- read a room; sends the full state only when it changed since p_since
create or replace function public.rr_get(p_code text, p_since integer default 0)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when r.code is null then null else
    jsonb_build_object('version', r.version, 'closes_at', r.closes_at, 'closed', r.closes_at < now(),
                       'state', case when r.version = p_since then null else r.state end)
  end
  from (select 1) one left join rr_rooms r on r.code = p_code;
$$;

-- save a new room state; returns the new version, -1 if someone else changed it first, -2 if not allowed
create or replace function public.rr_put(p_code text, p_pid text, p_token text, p_version integer, p_state jsonb)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare v integer;
begin
  if not rr_is_player(p_code, p_pid, p_token) or octet_length(p_state::text) > 300000 then return -2; end if;
  if exists (select 1 from rr_rooms where code = p_code and closes_at < now()) then return -2; end if;
  update rr_rooms set state = p_state, version = version + 1, updated_at = now()
    where code = p_code and version = p_version returning version into v;
  return coalesce(v, -1);
end $$;

-- store one part of a recorded verse (the game splits recordings into parts)
create or replace function public.rr_add_part(p_code text, p_pid text, p_token text, p_id text,
                                              p_part integer, p_parts integer, p_data text)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare b bytea;
begin
  if not rr_is_player(p_code, p_pid, p_token) then return false; end if;
  if exists (select 1 from rr_rooms where code = p_code and closes_at < now()) then return false; end if;
  if p_id !~ '^[a-z0-9]{6,16}$' or p_parts not between 1 and 8 or p_part not between 0 and p_parts - 1 then return false; end if;
  b := decode(p_data, 'base64');
  if octet_length(b) > 200000 then return false; end if;
  if (select count(distinct id) from rr_verse_parts where code = p_code) >= 80 then return false; end if;
  insert into rr_verse_parts (code, id, part, parts, pid, data) values (p_code, p_id, p_part, p_parts, p_pid, b)
    on conflict (code, id, part) do update set data = excluded.data, parts = excluded.parts
    where rr_verse_parts.pid = p_pid;
  return true;
end $$;

-- read a recorded verse: a list of base64 parts in order, or null if it is incomplete
create or replace function public.rr_verse(p_code text, p_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when count(*) > 0 and count(*) = max(parts)
    then jsonb_agg(replace(encode(data, 'base64'), E'\n', '') order by part) else null end
  from rr_verse_parts where code = p_code and id = p_id;
$$;

grant execute on function public.rr_create(text, text, text, jsonb)                          to anon, authenticated;
grant execute on function public.rr_join(text, text, text)                                   to anon, authenticated;
grant execute on function public.rr_get(text, integer)                                       to anon, authenticated;
grant execute on function public.rr_put(text, text, text, integer, jsonb)                    to anon, authenticated;
grant execute on function public.rr_add_part(text, text, text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.rr_verse(text, text)                                        to anon, authenticated;
