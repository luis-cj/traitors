# The Traitors: game-night tool

Static front end (GitHub Pages) + Supabase (Postgres) for the secret parts. 10 players, 3 traitors picked by a server-side roulette (couples may both be picked; Eric and Martyna are always faithful), Zu as game master.

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
- Roulette: 3 traitors, uniform over all groups of 3 eligible players. Couples may both be picked. Players with `can_be_traitor = false` (Eric and Martyna) are never picked.
- **Zu picks each next step** after the reveal or any result: a banishment vote, a night, or the medics' shield. This lets you follow the weekend schedule (kills only on certain nights).
- Banishment: all living players vote, tallies and the banished role are revealed. A tie is settled by chance.
- Night: living traitors pick a victim (not a traitor), see each other's pick, and all must **lock in** the same one. Zu's dawn button warns if they have not agreed, and she can force it (chance decides). Zu sees a **Ready / Waiting** light that turns green once all living traitors have locked in the same victim (it never shows who or what). The same light appears for the medics' shield step.
- **Medics:** everyone who dies, banished or murdered, sees "You are dead. You have now become a medic, a dead medic." and joins the medics.
- **Shield step** (Zu opens it, needs at least one medic): all medics agree on **one** living person and each lock in. The shield protects that person in the **next round only** (a banishment or a murder), then it disappears.
  - A shielded murder target: "Nobody was murdered in the night. A shield protected X."
  - A shielded person with the most banishment votes: "X had the most votes, but a shield protected them. Nobody is banished."
  - If the medics do not agree, Zu can skip the shield.
  - Only medics can see who currently holds the shield.
- **Dead traitors** are medics too, but they cannot give shields, are not counted for the medics' agreement, and cannot see the shield or the medics' picks. Instead of the medic message they see "You are dead. You have now become a traitor advisor.", and they are **advisors**: at night they can suggest a victim to their living fellow traitors. The suggestion is shown to the living traitors but counts for nothing, so only the living traitors decide.
- Win: faithful win when no traitors are left; traitors win when they equal or outnumber the faithful.
- "Reset game" returns to the lobby and keeps login codes.

## Secret missions
- A third tab, **Secret Missions**. When the roulette spins, each player is dealt **2 random missions** from the pool. With at least 20 missions in the pool, all 20 dealt are different; with fewer, missions repeat across players (never twice for the same player).
- Missions stay hidden until the player taps **Show my missions** (they hide again after 20 seconds). Players tick them off themselves. Nobody, including the game master, can see anyone else's missions.
- The pool starts **empty**; until you add missions, nobody gets any. Add them in the Supabase SQL editor (the pool is not readable by the site):
  ```sql
  insert into missions (text) values
    ('First mission text'),
    ('Second mission text');
  ```
  Add them **before** the roulette spins. Missions are dealt at the spin, not afterwards. To clear the pool: `delete from missions where id > 0;`.

## Game-night tips
- Each player holds their own phone and taps the gold "Show my role" button to flip their card (it hides again after a tap or 12 seconds). Couples: turn away from each other.
- Keep paper slips as a fallback in case the site dies.

## Demo (all 10 players in one browser)
1. Create a throwaway Supabase project, enable anonymous sign-ins, and run all of `supabase/schema.sql`.
2. Generate the codes for the demo (safe, no roles in the query):
   ```sql
   select json_object_agg(name, code) from players;
   ```
   Paste the result inside `DEMO_CODES: { ... }` in `config.test.js`, and fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` there.
3. Start a local server:
   ```bash
   cd traitors_html && python3 -m http.server 8000
   ```
4. Open `http://localhost:8000/demo.html`. Ten phones appear, each already logged in as one player. Use Zu's frame to spin the roulette and advance the phases.

`config.test.js` is git-ignored and only used on localhost or a LAN IP, so the live site never sees it.
