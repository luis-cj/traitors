-- The Traitors: database schema + game logic
-- Run this whole file once in the Supabase SQL editor (on a fresh project).
--
-- Security model: clients have NO direct table access. Everything goes through
-- the SECURITY DEFINER functions at the bottom, which only ever return what the
-- calling player is allowed to see. Roles live in their own table (`roles`) so
-- that browsing `players` (e.g. to copy login codes) never reveals a secret.

-- ---------- tables ----------

create table game_state (
  id           int primary key default 1 check (id = 1),
  phase        text not null default 'lobby',  -- lobby, reveal, night, day, banish, banish_result, ended
  round        int  not null default 0,
  spin_id      int  not null default 0,
  announcement text not null default '',
  winner       text,
  tally        jsonb not null default '[]'
);
insert into game_state default values;

create table players (
  id         serial primary key,
  name       text unique not null,
  partner_id int references players(id),
  code       text not null,              -- personal login code
  auth_uid   uuid,                       -- set when the player logs in
  is_admin   boolean not null default false,
  alive      boolean not null default true,
  can_be_traitor boolean not null default true
);

create table roles (                      -- NEVER open this table yourself
  player_id int primary key references players(id) on delete cascade,
  role      text not null check (role in ('traitor', 'faithful'))
);

create table votes (
  kind      text not null check (kind in ('night', 'banish')),
  round     int  not null,
  voter_id  int  not null references players(id) on delete cascade,
  target_id int  not null references players(id) on delete cascade,
  primary key (kind, round, voter_id)
);

-- ---------- seed ----------

insert into players (name, code, is_admin)
select n, substr(md5(random()::text || n), 1, 6), (n = 'Zu')
from unnest(array['Luis','Zu','Alice','Justo','Eric','Gabriela','Jesus','Judit','Martyna','Owen']) as n;

-- players who must always be faithful
update players set can_be_traitor = false where name = 'Eric';

-- couples (set both directions)
do $$
declare pair text[];
begin
  foreach pair slice 1 in array array[['Luis','Zu'],['Alice','Justo'],['Eric','Gabriela'],['Jesus','Judit']] loop
    update players set partner_id = (select id from players where name = pair[2]) where name = pair[1];
    update players set partner_id = (select id from players where name = pair[1]) where name = pair[2];
  end loop;
end $$;

-- ---------- lock down tables ----------

alter table game_state enable row level security;
alter table players    enable row level security;
alter table roles      enable row level security;
alter table votes      enable row level security;
revoke all on game_state, players, roles, votes from anon, authenticated;

-- ---------- helpers (not callable by clients) ----------

create function _require_admin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from players where auth_uid = auth.uid() and is_admin) then
    raise exception 'admin only';
  end if;
end $$;

create function _check_win() returns text
language plpgsql security definer set search_path = public as $$
declare t int; f int;
begin
  select count(*) filter (where r.role = 'traitor'), count(*) filter (where r.role = 'faithful')
    into t, f
    from players p join roles r on r.player_id = p.id
   where p.alive;
  if t = 0 then return 'faithful'; end if;
  if t >= f then return 'traitors'; end if;
  return null;
end $$;

-- ---------- player-facing functions ----------

-- Log in with a personal code (re-claiming from a new device is allowed).
create function claim_player(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare p players;
begin
  if auth.uid() is null then raise exception 'no session'; end if;
  select * into p from players where lower(code) = lower(trim(p_code));
  if not found then raise exception 'Wrong code'; end if;
  update players set auth_uid = null where auth_uid = auth.uid() and id <> p.id;
  update players set auth_uid = auth.uid() where id = p.id;
  return json_build_object('name', p.name);
end $$;

-- Everything the calling player is allowed to see.
create function get_state() returns json
language plpgsql security definer set search_path = public as $$
declare me players; g game_state; myrole text;
begin
  select * into me from players where auth_uid = auth.uid();
  if not found then return json_build_object('error', 'not_claimed'); end if;
  select * into g from game_state;
  select role into myrole from roles where player_id = me.id;

  return json_build_object(
    'phase', g.phase, 'round', g.round, 'spin_id', g.spin_id,
    'announcement', g.announcement, 'winner', g.winner, 'tally', g.tally,
    'me', json_build_object('name', me.name, 'is_admin', me.is_admin, 'alive', me.alive),
    'my_role', myrole,
    'allies', case when myrole = 'traitor' then
        (select coalesce(json_agg(p.name order by p.id), '[]'::json)
           from players p join roles r on r.player_id = p.id
          where r.role = 'traitor' and p.id <> me.id)
      else '[]'::json end,
    -- a role is public only once the player is dead or the game is over
    'players', (select json_agg(json_build_object(
                  'name', p.name, 'alive', p.alive,
                  'role', case when not p.alive or g.phase = 'ended' then r.role end) order by p.id)
                  from players p left join roles r on r.player_id = p.id),
    'my_vote', (select t.name from votes v join players t on t.id = v.target_id
                 where v.voter_id = me.id and v.round = g.round
                   and v.kind = case g.phase when 'night' then 'night' when 'banish' then 'banish' end),
    'vote_progress', case when g.phase = 'banish' then json_build_object(
        'voted', (select count(*) from votes where kind = 'banish' and round = g.round
                    and voter_id in (select id from players where alive)),
        'total', (select count(*) from players where alive)) end
  );
end $$;

-- p_kind = 'night' (traitors only) or 'banish' (everyone alive). Votes can be changed until the phase closes.
create function cast_vote(p_kind text, p_target text) returns void
language plpgsql security definer set search_path = public as $$
declare me players; g game_state; t players; myrole text; trole text;
begin
  select * into me from players where auth_uid = auth.uid();
  if not found then raise exception 'not logged in'; end if;
  if not me.alive then raise exception 'You are out of the game'; end if;
  select * into g from game_state;
  select * into t from players where name = p_target and alive;
  if not found then raise exception 'Invalid target'; end if;
  select role into myrole from roles where player_id = me.id;
  select role into trole  from roles where player_id = t.id;

  if p_kind = 'night' then
    if g.phase <> 'night' then raise exception 'Not night time'; end if;
    if myrole <> 'traitor' then raise exception 'Only traitors vote at night'; end if;
    if trole = 'traitor' then raise exception 'You cannot murder a traitor'; end if;
  elsif p_kind = 'banish' then
    if g.phase <> 'banish' then raise exception 'Voting is not open'; end if;
    if t.id = me.id then raise exception 'You cannot vote for yourself'; end if;
  else
    raise exception 'Unknown vote kind';
  end if;

  insert into votes (kind, round, voter_id, target_id) values (p_kind, g.round, me.id, t.id)
  on conflict (kind, round, voter_id) do update set target_id = excluded.target_id;
end $$;

-- ---------- admin (Zu) functions: none of these return role information ----------

-- The roulette: 2 random traitors from the eligible players (couples allowed).
-- Uniform over all pairs of eligible players.
create or replace function admin_spin() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if (select phase from game_state) <> 'lobby' then raise exception 'Roulette already spun'; end if;
  delete from roles;
  insert into roles (player_id, role)
    select p.id, case when p.id in (select id from players where can_be_traitor order by random() limit 2)
                      then 'traitor' else 'faithful' end
      from players p;
  update game_state set phase = 'reveal', round = 0, spin_id = spin_id + 1,
         announcement = '', winner = null, tally = '[]';
end $$;

-- Moves the game on one step: reveal -> night -> day -> banish -> banish_result -> night ...
create function admin_advance() returns void
language plpgsql security definer set search_path = public as $$
declare g game_state; tgt int; tname text; trole text; w text; top int; ties int; tal jsonb;
begin
  perform _require_admin();
  select * into g from game_state;

  if g.phase = 'reveal' then
    update game_state set phase = 'night', round = 1, announcement = '', tally = '[]';

  elsif g.phase = 'night' then
    -- plurality among living traitors' votes; ties (or no votes) are settled by chance
    select target_id into tgt from votes
     where kind = 'night' and round = g.round
       and voter_id in (select p.id from players p join roles r on r.player_id = p.id
                         where p.alive and r.role = 'traitor')
       and target_id in (select id from players where alive)
     group by target_id order by count(*) desc, random() limit 1;
    if tgt is null then
      select p.id into tgt from players p join roles r on r.player_id = p.id
       where p.alive and r.role = 'faithful' order by random() limit 1;
    end if;
    update players set alive = false where id = tgt;
    select p.name, r.role into tname, trole from players p join roles r on r.player_id = p.id where p.id = tgt;
    w := _check_win();
    update game_state set announcement = tname || ' was murdered in the night. They were a ' || trole || '.',
           phase = case when w is null then 'day' else 'ended' end, winner = w;

  elsif g.phase = 'day' then
    update game_state set phase = 'banish', announcement = '', tally = '[]';

  elsif g.phase = 'banish' then
    select coalesce(jsonb_agg(jsonb_build_object('name', n, 'count', c) order by c desc), '[]'), coalesce(max(c), 0)
      into tal, top
      from (select t.name n, count(*) c from votes v join players t on t.id = v.target_id
             where v.kind = 'banish' and v.round = g.round and t.alive
             group by t.name) s;
    if top = 0 then
      update game_state set phase = 'banish_result', announcement = 'Nobody voted. Nobody is banished.', tally = '[]';
    else
      select count(*) into ties from (select t.id from votes v join players t on t.id = v.target_id
             where v.kind = 'banish' and v.round = g.round and t.alive
             group by t.id having count(*) = top) s;
      select t.id into tgt from votes v join players t on t.id = v.target_id
       where v.kind = 'banish' and v.round = g.round and t.alive
       group by t.id order by count(*) desc, random() limit 1;
      update players set alive = false where id = tgt;
      select p.name, r.role into tname, trole from players p join roles r on r.player_id = p.id where p.id = tgt;
      w := _check_win();
      update game_state set
        announcement = tname || ' was banished. They were a ' || trole || '.'
                       || case when ties > 1 then ' (Tie broken by chance.)' else '' end,
        tally = tal, phase = case when w is null then 'banish_result' else 'ended' end, winner = w;
    end if;

  elsif g.phase = 'banish_result' then
    update game_state set phase = 'night', round = round + 1, announcement = '', tally = '[]';

  else
    raise exception 'Nothing to advance from phase %', g.phase;
  end if;
end $$;

-- Back to the lobby (wipes roles, votes, deaths). Login codes are kept.
create function admin_reset() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  delete from votes;
  delete from roles;
  update players set alive = true;
  update game_state set phase = 'lobby', round = 0, announcement = '', winner = null, tally = '[]';
end $$;

-- ---------- permissions ----------

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function claim_player(text), get_state(), cast_vote(text, text),
                          admin_spin(), admin_advance(), admin_reset() to authenticated;

-- To get everyone's login code (safe: no roles in this query):
--   select name, code from players order by id;
