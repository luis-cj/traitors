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
  tally        jsonb not null default '[]',
  nights       int  not null default 0,   -- night steps started so far
  banishes     int  not null default 0,   -- banishment steps started so far
  shield_id    int                        -- medics' shield: protects this player in the next round only
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

alter table game_state add constraint game_state_shield_fk
  foreign key (shield_id) references players(id) on delete set null;

create table roles (                      -- NEVER open this table yourself
  player_id int primary key references players(id) on delete cascade,
  role      text not null check (role in ('traitor', 'faithful'))
);

create table votes (
  kind      text not null check (kind in ('night', 'banish', 'shield', 'advise')),
  round     int  not null,
  voter_id  int  not null references players(id) on delete cascade,
  target_id int  not null references players(id) on delete cascade,
  locked    boolean not null default false,  -- traitors' night pick locked in
  primary key (kind, round, voter_id)
);

-- secret missions: a pool, and 2 missions dealt to each player when the roulette spins
create table missions (
  id   serial primary key,
  text text not null
);
create table player_missions (
  player_id  int not null references players(id) on delete cascade,
  mission_id int not null references missions(id) on delete cascade,
  done       boolean not null default false,
  primary key (player_id, mission_id)
);

-- ---------- seed ----------

insert into players (name, code, is_admin)
select n, substr(md5(random()::text || n), 1, 6), (n = 'Zu')
from unnest(array['Luis','Zu','Alice','Justo','Eric','Gabriela','Jesus','Judit','Martyna','Owen']) as n;

-- players who must always be faithful
update players set can_be_traitor = false where name in ('Eric', 'Martyna');

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
alter table missions   enable row level security;
alter table player_missions enable row level security;
revoke all on game_state, players, roles, votes, missions, player_missions from anon, authenticated;

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

-- Zu's "ready" light: have all living traitors locked in the same victim?
create function _night_ready(p_round int) returns boolean
language plpgsql security definer stable set search_path = public as $$
begin
  return coalesce((
    select count(*) > 0
       and count(*) = (select count(*) from players p join roles r on r.player_id = p.id where p.alive and r.role = 'traitor')
       and count(distinct v.target_id) = 1
      from votes v
     where v.kind = 'night' and v.round = p_round and v.locked
       and v.voter_id in (select p.id from players p join roles r on r.player_id = p.id
                           where p.alive and r.role = 'traitor')), false);
end $$;

-- ... and have all medics who can give a shield locked in the same living person?
create function _shield_ready(p_round int) returns boolean
language plpgsql security definer stable set search_path = public as $$
begin
  return coalesce((
    select count(*) > 0
       and count(*) = (select count(*) from players p join roles r on r.player_id = p.id where not p.alive and r.role <> 'traitor')
       and count(distinct v.target_id) = 1
      from votes v
     where v.kind = 'shield' and v.round = p_round and v.locked
       and v.voter_id in (select p.id from players p join roles r on r.player_id = p.id
                           where not p.alive and r.role <> 'traitor')
       and v.target_id in (select id from players where alive)), false);
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
declare me players; g game_state; myrole text; vk text;
begin
  select * into me from players where auth_uid = auth.uid();
  if not found then return json_build_object('error', 'not_claimed'); end if;
  select * into g from game_state;
  select role into myrole from roles where player_id = me.id;
  vk := case g.phase when 'night' then (case when me.alive then 'night' else 'advise' end)
                     when 'banish' then 'banish' when 'shield' then 'shield' end;

  return json_build_object(
    'phase', g.phase, 'round', g.round, 'spin_id', g.spin_id,
    'n', case g.phase when 'banish' then g.banishes when 'night' then g.nights end,
    'announcement', g.announcement, 'winner', g.winner, 'tally', g.tally,
    'me', json_build_object('name', me.name, 'is_admin', me.is_admin, 'alive', me.alive),
    'my_role', myrole,
    -- only my own secret missions
    'missions', (select coalesce(json_agg(json_build_object('id', mi.id, 'text', mi.text, 'done', pm.done) order by mi.id), '[]'::json)
                   from player_missions pm join missions mi on mi.id = pm.mission_id where pm.player_id = me.id),
    'medic_count', (select count(*) from players where not alive),
    -- medics who can give shields: dead players who are not traitors
    'shield_medics', (select count(*) from players p join roles r on r.player_id = p.id where not p.alive and r.role <> 'traitor'),
    -- only voting medics (dead, not traitors) may know who currently holds the shield
    'shield', case when not me.alive and myrole is distinct from 'traitor' then (select name from players where id = g.shield_id) end,
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
                 where v.voter_id = me.id and v.round = g.round and v.kind = vk),
    'my_locked', coalesce((select v.locked from votes v
                 where v.voter_id = me.id and v.round = g.round and v.kind = vk and vk in ('night', 'shield')), false),
    -- traitors only: what the other living traitor has picked tonight
    'ally_picks', case when myrole = 'traitor' and g.phase = 'night' then
        (select coalesce(json_agg(json_build_object('name', p.name, 'pick', t.name, 'locked', coalesce(v.locked, false))
                                  order by p.id), '[]'::json)
           from players p join roles r on r.player_id = p.id and r.role = 'traitor'
           left join votes v on v.voter_id = p.id and v.kind = 'night' and v.round = g.round
           left join players t on t.id = v.target_id
          where p.alive and p.id <> me.id)
      else '[]'::json end,
    -- the living traitor sees what the dead traitors suggest (advice only, it counts for nothing)
    'advisor_picks', case when myrole = 'traitor' and me.alive and g.phase = 'night' then
        (select coalesce(json_agg(json_build_object('name', p.name, 'pick', t.name) order by p.id), '[]'::json)
           from players p join roles r on r.player_id = p.id and r.role = 'traitor'
           left join votes v on v.voter_id = p.id and v.kind = 'advise' and v.round = g.round
           left join players t on t.id = v.target_id
          where not p.alive)
      else '[]'::json end,
    -- voting medics only: what the other voting medics have picked for the shield
    'medic_picks', case when not me.alive and myrole is distinct from 'traitor' and g.phase = 'shield' then
        (select coalesce(json_agg(json_build_object('name', p.name, 'pick', t.name, 'locked', coalesce(v.locked, false))
                                  order by p.id), '[]'::json)
           from players p
           left join votes v on v.voter_id = p.id and v.kind = 'shield' and v.round = g.round
           left join players t on t.id = v.target_id
          where not p.alive and p.id <> me.id and (select role from roles where player_id = p.id) <> 'traitor')
      else '[]'::json end,
    -- the game master only: is the current night / shield step ready to be resolved?
    'ready', case when me.is_admin and g.phase = 'night' then _night_ready(g.round)
                  when me.is_admin and g.phase = 'shield' then _shield_ready(g.round) end,
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
  if p_kind in ('night', 'banish') and not me.alive then raise exception 'You are out of the game'; end if;
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
  elsif p_kind = 'shield' then
    if me.alive then raise exception 'Only medics (dead players) give shields'; end if;
    if myrole = 'traitor' then raise exception 'Dead traitors cannot give shields'; end if;
    if g.phase <> 'shield' then raise exception 'Not the shield step'; end if;
  elsif p_kind = 'advise' then
    -- a dead traitor's non-binding suggestion for the night's victim
    if me.alive or myrole <> 'traitor' then raise exception 'Only dead traitors can advise'; end if;
    if g.phase <> 'night' then raise exception 'Not night time'; end if;
    if trole = 'traitor' then raise exception 'You cannot murder a traitor'; end if;
  else
    raise exception 'Unknown vote kind';
  end if;

  -- changing your pick unlocks it; re-tapping the same target keeps the lock
  insert into votes (kind, round, voter_id, target_id) values (p_kind, g.round, me.id, t.id)
  on conflict (kind, round, voter_id) do update
    set target_id = excluded.target_id,
        locked = votes.locked and votes.target_id = excluded.target_id;
end $$;

-- Traitors (at night) and medics (at the shield step) lock in, or unlock, their pick.
create function lock_vote(p_lock boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare me players; g game_state; myrole text; k text;
begin
  select * into me from players where auth_uid = auth.uid();
  if not found then raise exception 'not logged in'; end if;
  select * into g from game_state;
  select role into myrole from roles where player_id = me.id;
  if g.phase = 'night' and myrole = 'traitor' and me.alive then k := 'night';
  elsif g.phase = 'shield' and not me.alive and myrole <> 'traitor' then k := 'shield';
  else raise exception 'Nothing to lock';
  end if;
  update votes set locked = p_lock where kind = k and round = g.round and voter_id = me.id;
  if not found then raise exception 'Choose someone first'; end if;
end $$;

-- A player ticks (or unticks) one of their own missions.
create function mark_mission(p_mission int, p_done boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  select * into me from players where auth_uid = auth.uid();
  if not found then raise exception 'not logged in'; end if;
  update player_missions set done = p_done where player_id = me.id and mission_id = p_mission;
  if not found then raise exception 'Not your mission'; end if;
end $$;

-- ---------- admin (Zu) functions: none of these return role information ----------

-- The roulette: 2 random traitors from the eligible players (couples allowed).
-- Uniform over all pairs of eligible players.
create or replace function admin_spin() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if (select phase from game_state) <> 'lobby' then raise exception 'Roulette already spun'; end if;
  delete from roles where player_id > 0;
  insert into roles (player_id, role)
    select p.id, case when p.id in (select id from players where can_be_traitor order by random() limit 2)
                      then 'traitor' else 'faithful' end
      from players p;
  -- deal 2 missions per player from a shuffled pool: all different when the pool has at least 20,
  -- otherwise they repeat across players (never twice for the same player unless the pool has 1)
  delete from player_missions where player_id > 0;
  insert into player_missions (player_id, mission_id)
    select s.player_id, m.id
      from (select p.id as player_id, row_number() over (order by p.id, k) as slot
              from players p cross join generate_series(1, 2) k) s
      join (select id, row_number() over (order by random()) as rn, count(*) over () as total from missions) m
        on m.rn = ((s.slot - 1) % m.total) + 1
    on conflict do nothing;
  update game_state set phase = 'reveal', round = 0, nights = 0, banishes = 0, shield_id = null,
         spin_id = spin_id + 1, announcement = '', winner = null, tally = '[]' where id = 1;
end $$;

-- Zu starts the next step. Allowed after the reveal or after any result.
-- p_next: 'banish' | 'night' | 'shield' (the medics' shield; needs at least one medic)
create function admin_goto(p_next text) returns void
language plpgsql security definer set search_path = public as $$
declare g game_state;
begin
  perform _require_admin();
  select * into g from game_state;
  if g.phase not in ('reveal', 'banish_result', 'day', 'shield_result') then
    raise exception 'Finish the current step first';
  end if;
  if p_next = 'banish' then
    update game_state set phase = 'banish', round = round + 1, banishes = banishes + 1,
           announcement = '', tally = '[]' where id = 1;
  elsif p_next = 'night' then
    update game_state set phase = 'night', round = round + 1, nights = nights + 1,
           announcement = '', tally = '[]' where id = 1;
  elsif p_next = 'shield' then
    if not exists (select 1 from players p join roles r on r.player_id = p.id where not p.alive and r.role <> 'traitor') then
      raise exception 'There are no medics who can give a shield yet';
    end if;
    update game_state set phase = 'shield', round = round + 1,
           announcement = '', tally = '[]' where id = 1;
  else
    raise exception 'Unknown step';
  end if;
end $$;

-- Resolves the step that is currently open: banish, night or shield.
create function admin_advance(p_force boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare g game_state; tgt int; tname text; trole text; w text; top int; ties int; tal jsonb;
        lc int; ld int; nt int; nm int; tg int;
begin
  perform _require_admin();
  select * into g from game_state;

  if g.phase = 'night' then
    -- the living traitors must all have locked in the same victim, unless the game master forces it
    select count(*), count(distinct v.target_id) into lc, ld from votes v
     where v.kind = 'night' and v.round = g.round and v.locked
       and v.voter_id in (select p.id from players p join roles r on r.player_id = p.id
                           where p.alive and r.role = 'traitor');
    select count(*) into nt from players p join roles r on r.player_id = p.id
     where p.alive and r.role = 'traitor';
    if not p_force and not (nt > 0 and lc = nt and ld = 1) then
      raise exception 'The traitors have not agreed yet';
    end if;

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
    select name into tname from players where id = tgt;
    if g.shield_id is not null and tgt = g.shield_id then
      update game_state set phase = 'day', shield_id = null,
             announcement = 'Nobody was murdered in the night. A shield protected ' || tname || '.' where id = 1;
    else
      update players set alive = false where id = tgt;
      select r.role into trole from roles r where r.player_id = tgt;
      w := _check_win();
      update game_state set announcement = tname || ' was murdered in the night. They were a ' || trole || '.',
             phase = case when w is null then 'day' else 'ended' end, winner = w, shield_id = null where id = 1;
    end if;

  elsif g.phase = 'banish' then
    select coalesce(jsonb_agg(jsonb_build_object('name', n, 'count', c) order by c desc), '[]'), coalesce(max(c), 0)
      into tal, top
      from (select t.name n, count(*) c from votes v join players t on t.id = v.target_id
             where v.kind = 'banish' and v.round = g.round and t.alive
             group by t.name) s;
    if top = 0 then
      update game_state set phase = 'banish_result', shield_id = null,
             announcement = 'Nobody voted. Nobody is banished.', tally = '[]' where id = 1;
    else
      select count(*) into ties from (select t.id from votes v join players t on t.id = v.target_id
             where v.kind = 'banish' and v.round = g.round and t.alive
             group by t.id having count(*) = top) s;
      select t.id into tgt from votes v join players t on t.id = v.target_id
       where v.kind = 'banish' and v.round = g.round and t.alive
       group by t.id order by count(*) desc, random() limit 1;
      select name into tname from players where id = tgt;
      if g.shield_id is not null and tgt = g.shield_id then
        update game_state set phase = 'banish_result', shield_id = null, tally = tal,
               announcement = tname || ' had the most votes, but a shield protected them. Nobody is banished.'
                              || case when ties > 1 then ' (Tie broken by chance.)' else '' end where id = 1;
      else
        update players set alive = false where id = tgt;
        select r.role into trole from roles r where r.player_id = tgt;
        w := _check_win();
        update game_state set
          announcement = tname || ' was banished. They were a ' || trole || '.'
                         || case when ties > 1 then ' (Tie broken by chance.)' else '' end,
          tally = tal, phase = case when w is null then 'banish_result' else 'ended' end,
          winner = w, shield_id = null
          where id = 1;
      end if;
    end if;

  elsif g.phase = 'shield' then
    -- every medic (dead player) must have locked in the same living person, unless the game master skips it
    select count(*) into nm from players p join roles r on r.player_id = p.id where not p.alive and r.role <> 'traitor';
    select count(*), count(distinct v.target_id), min(v.target_id) into lc, ld, tg from votes v
     where v.kind = 'shield' and v.round = g.round and v.locked
       and v.voter_id in (select p.id from players p join roles r on r.player_id = p.id where not p.alive and r.role <> 'traitor')
       and v.target_id in (select id from players where alive);
    if nm > 0 and lc = nm and ld = 1 then
      update game_state set phase = 'shield_result', shield_id = tg, announcement = '' where id = 1;
    elsif p_force then
      update game_state set phase = 'shield_result', shield_id = null, announcement = '' where id = 1;
    else
      raise exception 'The medics have not agreed yet';
    end if;

  else
    raise exception 'Nothing to resolve. Pick the next step (banishment, night or shield).';
  end if;
end $$;

-- Back to the lobby (wipes roles, votes, deaths). Login codes are kept.
create or replace function admin_reset() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  delete from votes where round >= 0;
  delete from player_missions where player_id > 0;
  delete from roles where player_id > 0;
  update players set alive = true where id > 0;
  update game_state set phase = 'lobby', round = 0, nights = 0, banishes = 0, shield_id = null,
         announcement = '', winner = null, tally = '[]' where id = 1;
end $$;

-- ---------- permissions ----------

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function claim_player(text), get_state(), cast_vote(text, text), lock_vote(boolean), mark_mission(int, boolean),
                          admin_spin(), admin_goto(text), admin_advance(boolean), admin_reset() to authenticated;

-- To get everyone's login code (safe: no roles in this query):
--   select name, code from players order by id;
