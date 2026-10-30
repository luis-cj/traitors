// Demo mode (localhost / LAN only): index.html?demo=Name logs in as that player with its own session,
// so demo.html can show many players side by side in one browser.
const isLocal = location.hostname === "localhost" || /^\d+\.\d+\.\d+\.\d+$/.test(location.hostname);
const demoName = isLocal ? new URLSearchParams(location.search).get("demo") : null;
const sb = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY,
  demoName ? { auth: { storageKey: "sb-demo-" + demoName } } : undefined);
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const store = {
  get(k) { try { return localStorage.getItem((demoName || "") + k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem((demoName || "") + k, v); } catch {} },
};

let state = null, lastKey = "", tab = "game";

// Calls a database function; if the browser has lost its session (permission denied),
// starts a fresh anonymous session and retries once.
async function rpc(fn, args) {
  let res = await sb.rpc(fn, args);
  if (res.error && res.error.code === "42501") {
    await sb.auth.signOut({ scope: "local" });
    const { error } = await sb.auth.signInAnonymously();
    if (!error) res = await sb.rpc(fn, args);
  }
  return res;
}

// ---------- boot / polling ----------

async function init() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    const { error } = await sb.auth.signInAnonymously();
    if (error) return ($("#app").innerHTML = `<p class="card">Could not start a session: ${esc(error.message)}</p>`);
  }
  await refresh();
  const code = demoName && CONFIG.DEMO_CODES && CONFIG.DEMO_CODES[demoName];
  if (code && state && state.error === "not_claimed") {
    await rpc("claim_player", { p_code: code });
    lastKey = "";
    await refresh();
  }
  setInterval(refresh, 2500);
}

async function refresh() {
  const { data, error } = await rpc("get_state");
  if (error) return;
  state = data;
  const key = JSON.stringify(state) + tab;
  if (key === lastKey) return;
  lastKey = key;
  render();
}

async function adminCall(fn, args) {
  let { error } = await rpc(fn, args);
  if (error && error.message.includes("traitors have not agreed")) {
    if (!confirm("The traitors have not agreed yet. Force the dawn? Chance will pick the victim.")) return;
    ({ error } = await rpc(fn, { ...args, p_force: true }));
  } else if (error && error.message.includes("medics have not agreed")) {
    if (!confirm("The medics have not agreed yet. Skip the shield this round?")) return;
    ({ error } = await rpc(fn, { ...args, p_force: true }));
  }
  if (error) alert(error.message);
  lastKey = "";
  await refresh();
}

async function call(fn, args) {
  const { error } = await rpc(fn, args);
  if (error) alert(error.message);
  lastKey = "";
  await refresh();
}

// ---------- rendering ----------

function render() {
  const app = $("#app");
  const logged = state && !state.error;
  $("#nav").hidden = !logged;
  $("#peek").hidden = !(logged && state.my_role);
  document.querySelectorAll("nav button").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));

  if (!logged) return renderLogin(app);
  if (tab === "videos") return renderVideos(app);

  if (state.phase === "reveal" && (+store.get("traitors_spin") || 0) < state.spin_id) {
    store.set("traitors_spin", state.spin_id);
    playRoulette();
  } else if (state.phase !== "reveal") {
    store.set("traitors_spin", state.spin_id);
  }
  app.innerHTML = gameHtml();
}

function renderLogin(app) {
  app.innerHTML = `
    <div class="card">
      <h2>Who are you?</h2>
      <p class="muted">Enter your personal code.</p>
      <input id="code" placeholder="Code" autocapitalize="off" autocomplete="off">
      <button class="primary" data-act="login">Enter</button>
    </div>`;
}

function playersHtml() {
  return `<div class="card"><div class="chips">${state.players
    .map((p) => {
      const cls = ["chip", !p.alive && "dead", p.role].filter(Boolean).join(" ");
      return `<span class="${cls}">${esc(p.name)}${p.role ? " · " + p.role : ""}</span>`;
    })
    .join("")}</div></div>`;
}

function voteList(kind, targets) {
  return targets
    .map((n) => `<button class="choice ${state.my_vote === n ? "selected" : ""}" data-act="vote" data-kind="${kind}" data-target="${esc(n)}">${esc(n)}</button>`)
    .join("");
}

// Shows what the other group members have picked, the lock-in button and a status line.
function agreementHtml(mates, agreeText, who) {
  const s = state;
  const list = mates.map((a) => `<div class="tally"><span>${esc(a.name)}</span><span>${
    a.pick ? (a.locked ? "locked: " : "leaning: ") + esc(a.pick) : "has not chosen"}</span></div>`).join("");
  const agree = s.my_locked && mates.every((a) => a.locked && a.pick === s.my_vote);
  let note = "";
  if (s.my_locked) {
    note = agree ? agreeText
      : mates.some((a) => a.locked && a.pick !== s.my_vote) ? "You disagree. Someone must change."
      : `Waiting for ${who} to lock in.`;
  }
  const lock = s.my_vote
    ? `<button class="primary" data-act="lock" data-lock="${!s.my_locked}">${s.my_locked ? "Locked in. Tap to change" : "Lock in " + esc(s.my_vote)}</button>` : "";
  return `${list}${lock}${note ? `<p class="muted">${note}</p>` : ""}`;
}

function traitorNightHtml(targets) {
  const advice = (state.advisor_picks || []).filter((a) => a.pick)
    .map((a) => `<div class="tally"><span>${esc(a.name)} (dead advisor)</span><span>suggests: ${esc(a.pick)}</span></div>`).join("");
  return `<p>Choose who to murder. Both living traitors must lock in the same victim.</p>${voteList("night", targets)}` +
    advice + agreementHtml(state.ally_picks || [], "You agree. Wait for dawn.", "your partner");
}

// A dead traitor can only advise: a non-binding suggestion that counts for nothing in the lock-in.
function advisorNightHtml(targets) {
  const partner = (state.ally_picks || []).map((a) => `<div class="tally"><span>${esc(a.name)}</span><span>${
    a.pick ? (a.locked ? "locked: " : "leaning: ") + esc(a.pick) : "has not chosen"}</span></div>`).join("");
  return `<p>You are a dead traitor, now an advisor. Suggest a victim to your partner. It is only a suggestion: they decide.</p>${voteList("advise", targets)}${partner}`;
}

function medicShieldHtml(targets) {
  return `<p>You are a medic. All medics must agree on <b>one</b> living person to shield. The shield protects them in the next round only, whether it is a banishment or a murder.</p>${voteList("shield", targets)}` +
    agreementHtml(state.medic_picks || [], "All medics agree. Wait for the game master.", "the other medics");
}

// Zu chooses what happens next (after the reveal or any result).
function nextBtns() {
  if (!state.me.is_admin) return "";
  const b = (next, label) => `<button class="primary" data-act="goto" data-next="${next}" data-confirm="${esc(label)}?">${esc(label)}</button>`;
  return `<p class="muted" style="margin:16px 0 0">Next step:</p>` +
    b("banish", "Open a banishment vote") + b("night", "Start a night (traitors choose)") +
    (state.shield_medics > 0 ? b("shield", "Open the medics' shield") : "");
}

// Game master only: tells Zu whether the traitors / medics have all locked in, so she knows when to press the button.
function readyHtml(waiting, done) {
  if (!state.me.is_admin || typeof state.ready !== "boolean") return "";
  return `<div class="ready ${state.ready ? "yes" : ""}">${state.ready ? "Ready: " + esc(done) : "Waiting: " + esc(waiting)}</div>`;
}

function adminBtn(label, fn) {
  return state.me.is_admin ? `<button class="primary" data-act="admin" data-fn="${fn}" data-confirm="${esc(label)}?">${esc(label)}</button>` : "";
}

function gameHtml() {
  const s = state, alive = s.players.filter((p) => p.alive).map((p) => p.name);
  const deadTraitor = !s.me.alive && s.my_role === "traitor", votingMedic = !s.me.alive && s.my_role !== "traitor";
  const out = s.me.alive ? "" : deadTraitor
    ? `<div class="card banner">You are dead. You have now become a traitor advisor.<br><small>You cannot give shields, but at night you can suggest a victim to your living partner.</small></div>`
    : `<div class="card banner">You are dead. You have now become a medic, a dead medic.</div>`
    + (s.shield ? `<p class="muted">The shield currently protects: <b>${esc(s.shield)}</b> (next round only)</p>` : "");
  const hello = `<p class="muted">Playing as <b>${esc(s.me.name)}</b>${s.me.is_admin ? " · Game master" : ""}${demoName ? ` · DEMO role: <b>${esc(s.my_role || "none yet")}</b>` : ""}</p>`;
  let body = "";

  switch (s.phase) {
    case "lobby":
      body = `<div class="card"><h2>The lobby</h2><p>Waiting for the game master to spin the roulette.</p></div>` +
        adminBtn("Spin the roulette", "admin_spin");
      break;
    case "reveal":
      body = `<div class="card"><h2>Fates sealed</h2><p>Tap the gold button at the bottom to flip your card and see your role. Tap again to hide it, and keep your screen hidden.</p></div>` +
        nextBtns();
      break;
    case "night": {
      const traitor = s.my_role === "traitor" && s.me.alive;
      const targets = alive.filter((n) => n !== s.me.name && !s.allies.includes(n));
      body = `<div class="card"><h2>Night ${s.n}</h2>` +
        (traitor ? traitorNightHtml(targets) : deadTraitor ? advisorNightHtml(targets) : `<p>The traitors are choosing a victim. Close your eyes.</p>`) +
        `</div>` + readyHtml("the traitors have not locked in yet.", "the traitors have locked in. You can press Dawn breaks.") +
        adminBtn("Dawn breaks (resolve the night)", "admin_advance");
      break;
    }
    case "day":
      body = `<div class="card"><p class="big">${esc(s.announcement)}</p></div>` + nextBtns();
      break;
    case "banish": {
      const vp = s.vote_progress;
      body = `<div class="card"><h2>Banishment ${s.n}</h2>` +
        (s.me.alive ? `<p>Who is a traitor?</p>${voteList("banish", alive.filter((n) => n !== s.me.name))}` : `<p>The living are voting.</p>`) +
        `<p class="muted">${vp.voted} of ${vp.total} have voted</p></div>` + adminBtn("Close the vote and reveal", "admin_advance");
      break;
    }
    case "banish_result":
      body = `<div class="card"><p class="big">${esc(s.announcement)}</p>${tallyHtml()}</div>` + nextBtns();
      break;
    case "shield":
      body = `<div class="card"><h2>The medics' shield</h2>` +
        (votingMedic ? medicShieldHtml(alive) : `<p>The medics are choosing who to shield.${deadTraitor ? " You cannot take part." : ""}</p>`) +
        `</div>` + readyHtml("the medics have not all locked in yet.", "the medics have agreed. You can lock in the shield.") +
        adminBtn("Lock in the shield", "admin_advance");
      break;
    case "shield_result":
      body = `<div class="card"><h2>The medics have decided</h2>` +
        (votingMedic ? `<p>${s.shield ? `The shield protects <b>${esc(s.shield)}</b> in the next round.` : "No shield this round."}</p>` : `<p>The shield is set.</p>`) +
        `</div>` + nextBtns();
      break;
    case "ended":
      body = `<div class="card"><h2>${s.winner === "traitors" ? "The traitors win" : "The faithful win"}</h2><p>${esc(s.announcement)}</p>${tallyHtml()}</div>`;
      break;
  }

  const reset = s.me.is_admin && s.phase !== "lobby"
    ? `<p style="margin-top:32px"><button class="danger" data-act="admin" data-fn="admin_reset" data-confirm="Reset the whole game? This erases roles and deaths.">Reset game</button></p>` : "";
  return hello + out + body + playersHtml() + reset;
}

function tallyHtml() {
  const t = state.tally || [];
  return t.length ? `<div>${t.map((r) => `<div class="tally"><span>${esc(r.name)}</span><b>${r.count}</b></div>`).join("")}</div>` : "";
}

// ---------- videos tab (light gate: speed bump only) ----------

async function sha256(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function renderVideos(app) {
  if (sessionStorage.getItem("videos_ok") !== "1") {
    app.innerHTML = `<div class="card"><h2>Videos</h2><p class="muted">Password needed.</p>
      <input id="vpass" type="password" placeholder="Password" autocapitalize="off" autocomplete="off" autocorrect="off"><button class="primary" data-act="unlock">Unlock</button></div>`;
    return;
  }
  const vids = CONFIG.VIDEOS.length ? CONFIG.VIDEOS : [];
  app.innerHTML = vids.length
    ? vids.map((v) => `<div class="card"><b>${esc(v.who)}</b><iframe class="video" src="https://www.youtube-nocookie.com/embed/${encodeURIComponent(v.youtubeId)}" allowfullscreen></iframe>${v.description ? `<p class="desc">${esc(v.description)}</p>` : ""}</div>`).join("")
    : `<div class="card muted">No videos yet.</div>`;
}

// ---------- roulette animation (cosmetic only: every phone shows the same thing) ----------

function playRoulette() {
  const el = $("#roulette");
  el.hidden = false;
  el.innerHTML = `<div class="wheel"></div><div class="role-word" id="spinWord">…</div>`;
  const word = $("#spinWord"), words = ["Traitor", "Faithful"];
  let i = 0, delay = 90;
  (function tick() {
    if (delay > 600) {
      el.querySelector(".wheel").classList.add("done");
      word.textContent = "The roulette has spoken";
      el.insertAdjacentHTML("beforeend", `<p class="muted">Tap the gold button to flip your card.</p><button class="primary" data-act="closeRoulette">Continue</button>`);
      return;
    }
    word.textContent = words[i++ % 2];
    word.className = "role-word " + words[(i - 1) % 2].toLowerCase();
    delay *= 1.18;
    setTimeout(tick, delay);
  })();
}

// ---------- events ----------

document.addEventListener("click", async (e) => {
  const b = e.target.closest("[data-act],[data-tab]");
  if (!b) return;
  if (b.dataset.tab) { tab = b.dataset.tab; lastKey = ""; return render(); }

  switch (b.dataset.act) {
    case "login": {
      const { error } = await rpc("claim_player", { p_code: $("#code").value });
      if (error) return alert(error.message);
      lastKey = ""; return refresh();
    }
    case "vote": return call("cast_vote", { p_kind: b.dataset.kind, p_target: b.dataset.target });
    case "admin":
      if (b.dataset.confirm && !confirm(b.dataset.confirm)) return;
      return adminCall(b.dataset.fn);
    case "goto":
      if (b.dataset.confirm && !confirm(b.dataset.confirm)) return;
      return adminCall("admin_goto", { p_next: b.dataset.next });
    case "lock": return call("lock_vote", { p_lock: b.dataset.lock === "true" });
    case "closeRoulette": $("#roulette").hidden = true; return;
    case "unlock": {
      const h = await sha256($("#vpass").value.trim());
      if (h === CONFIG.VIDEO_PASSWORD_SHA256) { sessionStorage.setItem("videos_ok", "1"); lastKey = ""; render(); }
      else alert("Wrong password");
    }
  }
});

// tap-to-flip role card (tap again, tap the card, or wait 12s to hide it)
const peek = $("#peek"), card = $("#roleCard");
let roleOpen = false, roleTimer = null;

function openRole() {
  if (!state?.my_role) return;
  const allies = state.allies.length ? `<p>Your fellow traitor: <b>${state.allies.map(esc).join(", ")}</b></p>` : "";
  card.innerHTML = `<div class="flip"><div class="flip-inner" id="flipInner">
      <div class="face back">?</div>
      <div class="face front"><div class="role-word ${state.my_role}">${state.my_role}</div>${allies}<p class="muted">Tap to hide</p></div>
    </div></div>`;
  card.hidden = false;
  roleOpen = true;
  peek.textContent = "Hide my role";
  requestAnimationFrame(() => requestAnimationFrame(() => $("#flipInner")?.classList.add("flipped")));
  clearTimeout(roleTimer);
  roleTimer = setTimeout(closeRole, 12000);
}

function closeRole() {
  if (!roleOpen) return;
  roleOpen = false;
  clearTimeout(roleTimer);
  peek.textContent = "Show my role";
  $("#flipInner")?.classList.remove("flipped");
  setTimeout(() => { if (!roleOpen) { card.hidden = true; card.innerHTML = ""; } }, 450);
}

peek.addEventListener("click", () => (roleOpen ? closeRole() : openRole()));
card.addEventListener("click", closeRole);

init();
