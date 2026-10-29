const sb = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY);
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} },
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

function adminBtn(label, fn) {
  return state.me.is_admin ? `<button class="primary" data-act="admin" data-fn="${fn}" data-confirm="${esc(label)}?">${esc(label)}</button>` : "";
}

function gameHtml() {
  const s = state, alive = s.players.filter((p) => p.alive).map((p) => p.name);
  const out = s.me.alive ? "" : `<div class="card banner">You are out of the game. Watch in silence.</div>`;
  const hello = `<p class="muted">Playing as <b>${esc(s.me.name)}</b>${s.me.is_admin ? " · Game master" : ""}</p>`;
  let body = "";

  switch (s.phase) {
    case "lobby":
      body = `<div class="card"><h2>The lobby</h2><p>Waiting for the game master to spin the roulette.</p></div>` +
        adminBtn("Spin the roulette", "admin_spin");
      break;
    case "reveal":
      body = `<div class="card"><h2>Fates sealed</h2><p>Hold the gold button at the bottom to see your role. Keep your screen hidden.</p></div>` +
        adminBtn("Begin night 1", "admin_advance");
      break;
    case "night": {
      const traitor = s.my_role === "traitor" && s.me.alive;
      const targets = alive.filter((n) => n !== s.me.name && !s.allies.includes(n));
      body = `<div class="card"><h2>Night ${s.round}</h2>` +
        (traitor ? `<p>Choose who to murder. If you disagree, chance decides.</p>${voteList("night", targets)}` : `<p>The traitors are choosing a victim. Close your eyes.</p>`) +
        `</div>` + adminBtn("Dawn breaks (resolve the night)", "admin_advance");
      break;
    }
    case "day":
      body = `<div class="card"><p class="big">${esc(s.announcement)}</p></div>` + adminBtn("Open the banishment vote", "admin_advance");
      break;
    case "banish": {
      const vp = s.vote_progress;
      body = `<div class="card"><h2>Banishment</h2>` +
        (s.me.alive ? `<p>Who is a traitor?</p>${voteList("banish", alive.filter((n) => n !== s.me.name))}` : `<p>The living are voting.</p>`) +
        `<p class="muted">${vp.voted} of ${vp.total} have voted</p></div>` + adminBtn("Close the vote and reveal", "admin_advance");
      break;
    }
    case "banish_result":
      body = `<div class="card"><p class="big">${esc(s.announcement)}</p>${tallyHtml()}</div>` + adminBtn("Next night", "admin_advance");
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
    ? vids.map((v) => `<div class="card"><b>${esc(v.who)}</b><iframe class="video" src="https://www.youtube-nocookie.com/embed/${encodeURIComponent(v.youtubeId)}" allowfullscreen></iframe></div>`).join("")
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
      el.insertAdjacentHTML("beforeend", `<p class="muted">Hold the gold button to see your fate.</p><button class="primary" data-act="closeRoulette">Continue</button>`);
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
      return call(b.dataset.fn);
    case "closeRoulette": $("#roulette").hidden = true; return;
    case "unlock": {
      const h = await sha256($("#vpass").value.trim());
      if (h === CONFIG.VIDEO_PASSWORD_SHA256) { sessionStorage.setItem("videos_ok", "1"); lastKey = ""; render(); }
      else alert("Wrong password");
    }
  }
});

// hold-to-reveal role
const peek = $("#peek"), card = $("#roleCard");
const showRole = () => {
  if (!state?.my_role) return;
  const allies = state.allies.length ? `<p>Your fellow traitor: <b>${state.allies.map(esc).join(", ")}</b></p>` : "";
  card.innerHTML = `<div class="role-word ${state.my_role}">${state.my_role}</div>${allies}`;
  card.hidden = false;
};
const hideRole = () => { card.hidden = true; card.innerHTML = ""; };
peek.addEventListener("pointerdown", (e) => { e.preventDefault(); showRole(); });
["pointerup", "pointerleave", "pointercancel"].forEach((ev) => peek.addEventListener(ev, hideRole));
peek.addEventListener("contextmenu", (e) => e.preventDefault());

init();
