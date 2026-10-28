# The Traitors: game-night tool

Static front end (GitHub Pages) + Supabase (Postgres) for the secret parts. 10 players, 2 traitors picked by a server-side roulette (couples may both be picked; Eric is always faithful), Zu as game master.

## How it keeps secrets
- Browsers have **no direct table access**. Every call goes through a database function that returns only what *that player* may see.
- Roles are in their own table, `roles`. **Nobody should ever open it.** The `players` table (names, login codes) is safe to browse.
- Zu's admin buttons (spin, advance, reset) never return role data.
- The roulette animation is cosmetic. The result is chosen in the database.

## Setup
1. **Supabase:** create a free project at supabase.com.
2. Authentication → Sign In / Providers → turn on **Allow anonymous sign-ins**.
3. SQL Editor → paste all of `supabase/schema.sql` → Run.
4. Get everyone's login code (this query is safe, no roles):
   ```sql
   select name, code from players order by id;
   ```
   Send each person their own code privately. If you have not edited the seed, codes are random.
5. Put your project URL and anon key (Project Settings → API) in `config.js`.
6. Videos tab: set `VIDEO_PASSWORD_SHA256` (`echo -n "pw" | shasum -a 256`) and list unlisted YouTube IDs in `VIDEOS`. This password is a speed bump only, the hash is visible in the page source.
7. **GitHub:** push this folder to a repo, Settings → Pages → deploy from `main` / root. Share the URL.

## Test without spoiling yourself
Testing reveals roles to whoever tests. Create a **second, throwaway Supabase project**, run the schema there, point `config.js` at it, and play fake rounds in separate incognito windows. Then switch `config.js` back to the clean real project before game night.

## Rules implemented
- Roulette: 2 traitors, uniform over all pairs of eligible players. Couples may both be picked. Players with `can_be_traitor = false` (Eric) are never picked.
- Night: living traitors vote for a victim (not a traitor). A split vote or no votes is settled by chance.
- Day: the victim's role is announced.
- Banishment: all living players vote, tallies and the banished role are revealed. A tie is settled by chance.
- Win: faithful win when no traitors are left; traitors win when they equal or outnumber the faithful.
- Zu's single button advances the phases. "Reset game" returns to the lobby and keeps login codes.

## Game-night tips
- Each player holds their own phone and uses the gold "hold to see my role" button. Couples: turn away from each other.
- Keep paper slips as a fallback in case the site dies.
