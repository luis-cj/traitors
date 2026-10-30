-- Pumpkin Awards: anonymous messages. Run in the Supabase SQL editor (safe to run more than once).
-- The table has NO author column, so nobody (not even whoever owns the project) can tell who wrote a message.
-- Only a logged-in player can post, and every logged-in player can read all messages.

create table if not exists pumpkin_messages (
  id         serial primary key,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
alter table pumpkin_messages enable row level security;
revoke all on pumpkin_messages from anon, authenticated;

create or replace function post_pumpkin(p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare t text := btrim(coalesce(p_body, ''));
begin
  if not exists (select 1 from players where auth_uid = auth.uid()) then raise exception 'not logged in'; end if;
  if t = '' then raise exception 'Write something first'; end if;
  if char_length(t) > 500 then raise exception 'Keep it under 500 characters'; end if;
  insert into pumpkin_messages (body) values (t);
end $$;

create or replace function get_pumpkin() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from players where auth_uid = auth.uid()) then raise exception 'not logged in'; end if;
  return coalesce((select jsonb_agg(m.body order by m.id desc) from pumpkin_messages m), '[]'::jsonb);
end $$;

revoke execute on function post_pumpkin(text), get_pumpkin() from public, anon, authenticated;
grant execute on function post_pumpkin(text), get_pumpkin() to authenticated;
