/**
 * Match result simulation — Instant result + Simulate match (20s momentum).
 */
import { supabase } from "./global.js";

function ensureMatchSimStyles() {
  if (document.getElementById("matchSimStyles")) return;
  const style = document.createElement("style");
  style.id = "matchSimStyles";
  style.textContent = MATCH_SIM_BANNER_STYLE;
  document.head.appendChild(style);
}

/**
 * @returns {Promise<{ enabled: boolean, isAdmin: boolean, error: string|null }>}
 */
export async function loadMatchSimStatus() {
  ensureMatchSimStyles();
  const { data, error } = await supabase.rpc("match_result_simulation_status");
  if (error) {
    console.warn("match_result_simulation_status:", error);
    return {
      enabled: false,
      isAdmin: false,
      error: error.message || "Simulation status unavailable (run match_result_simulation.sql)",
    };
  }
  const row = data && typeof data === "object" ? data : {};
  return {
    enabled: row.enabled === true || row.match_result_simulation_enabled === true,
    isAdmin: row.is_admin === true,
    error: null,
  };
}

export async function setMatchSimEnabled(enabled) {
  const { data, error } = await supabase.rpc("admin_set_match_result_simulation_enabled", {
    p_enabled: !!enabled,
  });
  if (error) throw error;
  return data?.match_result_simulation_enabled === true;
}

/**
 * @param {{ enabled: boolean, isAdmin?: boolean, error?: string|null }} status
 */
export function matchSimBannerHtml(status) {
  if (status?.error) {
    return `<p class="match-sim-banner match-sim-banner--err" id="matchSimBanner">${escapeHtml(status.error)}</p>`;
  }
  if (!status?.enabled && !status?.isAdmin) return "";

  const state = status.enabled
    ? `<span class="match-sim-on">ON</span> — Instant result &amp; Simulate match on your fixtures.`
    : `<span class="match-sim-off">OFF</span> — owners cannot simulate results.`;

  const toggle = status.isAdmin
    ? `<button type="button" class="btn-link match-sim-toggle" id="matchSimToggleBtn" data-next="${
        status.enabled ? "0" : "1"
      }">${status.enabled ? "Turn OFF" : "Turn ON"}</button>`
    : "";

  return `<p class="match-sim-banner" id="matchSimBanner">Match simulation ${state} ${toggle}</p>`;
}

export function wireMatchSimBannerToggle(onChanged) {
  const btn = document.getElementById("matchSimToggleBtn");
  if (!btn) return;
  btn.addEventListener("click", async () => {
    const next = btn.getAttribute("data-next") === "1";
    const label = next ? "Enable match simulation for all owners?" : "Disable match simulation?";
    if (!confirm(label)) return;
    btn.disabled = true;
    try {
      await setMatchSimEnabled(next);
      if (typeof onChanged === "function") await onChanged(next);
    } catch (err) {
      alert(err?.message || String(err));
      btn.disabled = false;
    }
  });
}

/** @deprecated use matchSimActionsHtml */
export function matchSimButtonHtml(fixtureId) {
  return matchSimActionsHtml(fixtureId);
}

export function matchSimActionsHtml(fixtureId) {
  const id = escapeHtml(String(fixtureId));
  return `<span class="sim-actions">
    <button type="button" class="btn-link sim-result-btn sim-instant-btn" data-sim-fixture="${id}" data-sim-mode="instant">Instant result</button>
    <button type="button" class="btn-link sim-result-btn sim-play-btn" data-sim-fixture="${id}" data-sim-mode="play">Simulate match</button>
  </span>`;
}

/**
 * @param {(fixtureId: string, btn: HTMLButtonElement, mode: 'instant'|'play') => void} handler
 */
export function wireMatchSimButtons(root, handler) {
  root?.querySelectorAll("[data-sim-fixture]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-sim-fixture");
      if (!id) return;
      const mode = btn.getAttribute("data-sim-mode") === "play" ? "play" : "instant";
      handler(id, btn, mode);
    });
  });
}

/**
 * @param {string|number} fixtureId
 * @param {HTMLButtonElement|null} btn
 * @param {'instant'|'play'} [mode]
 * @param {{ homeName?: string, awayName?: string }} [meta]
 */
export async function runMatchSimulation(fixtureId, btn, mode = "instant", meta = {}) {
  const play = mode === "play";
  const group = btn?.closest?.(".sim-actions");
  const buttons = group
    ? [...group.querySelectorAll("button")]
    : btn
      ? [btn]
      : [];

  buttons.forEach((b) => {
    b.disabled = true;
    if (b === btn) b.textContent = play ? "Simulating…" : "Result…";
  });

  const { data, error } = await supabase.rpc("competition_simulate_fixture_result", {
    p_fixture_id: Number(fixtureId),
  });

  if (error) {
    buttons.forEach((b) => {
      b.disabled = false;
      if (b.classList.contains("sim-play-btn")) b.textContent = "Simulate match";
      else if (b.classList.contains("sim-instant-btn")) b.textContent = "Instant result";
      else b.textContent = "Simulate";
    });
    throw error;
  }

  const score =
    data?.home_goals != null && data?.away_goals != null
      ? `${data.home_goals}–${data.away_goals}`
      : "";

  if (play) {
    await playMatchMomentum(data, {
      homeName: meta.homeName || data?.home_name || data?.home_club,
      awayName: meta.awayName || data?.away_name || data?.away_club,
    });
  }

  buttons.forEach((b) => {
    b.textContent = score ? `Done ${score}` : "Done";
  });

  return data;
}

function ensureOverlay() {
  let el = document.getElementById("matchSimOverlay");
  if (el) return el;
  el = document.createElement("div");
  el.id = "matchSimOverlay";
  el.className = "msim-overlay";
  el.hidden = true;
  el.innerHTML = `
    <div class="msim-modal" role="dialog" aria-modal="true" aria-label="Match simulation">
      <div class="msim-head">
        <div class="msim-teams">
          <span class="msim-home-name" id="msimHomeName">Home</span>
          <span class="msim-score" id="msimScore">0 – 0</span>
          <span class="msim-away-name" id="msimAwayName">Away</span>
        </div>
        <div class="msim-clock" id="msimClock">1'</div>
      </div>
      <div class="msim-pitch">
        <div class="msim-bar" id="msimBar">
          <div class="msim-home-zone" id="msimHomeZone"></div>
          <div class="msim-away-zone" id="msimAwayZone"></div>
          <div class="msim-arrow" id="msimArrow" aria-hidden="true">▶</div>
        </div>
      </div>
      <div class="msim-feed" id="msimFeed"></div>
      <div class="msim-foot">
        <button type="button" class="btn-link msim-skip" id="msimSkip">Skip to result</button>
      </div>
    </div>
  `;
  document.body.appendChild(el);
  return el;
}

/**
 * @param {object} data RPC result
 * @param {{ homeName?: string, awayName?: string }} labels
 */
export function playMatchMomentum(data, labels = {}) {
  return new Promise((resolve) => {
    const overlay = ensureOverlay();
    const feed = overlay.querySelector("#msimFeed");
    const scoreEl = overlay.querySelector("#msimScore");
    const clockEl = overlay.querySelector("#msimClock");
    const arrow = overlay.querySelector("#msimArrow");
    const homeZone = overlay.querySelector("#msimHomeZone");
    const awayZone = overlay.querySelector("#msimAwayZone");
    const skipBtn = overlay.querySelector("#msimSkip");

    const homeColor = data?.colours?.home?.primary || "#3b82f6";
    const awayColor = data?.colours?.away?.primary || "#ef4444";
    homeZone.style.background = `linear-gradient(90deg, ${homeColor}, ${homeColor}99)`;
    awayZone.style.background = `linear-gradient(90deg, ${awayColor}99, ${awayColor})`;

    overlay.querySelector("#msimHomeName").textContent =
      labels.homeName || data?.home_name || data?.home_club || "Home";
    overlay.querySelector("#msimAwayName").textContent =
      labels.awayName || data?.away_name || data?.away_club || "Away";

    const playback = data?.playback || {};
    const duration = Math.max(8, Number(playback.duration_sec) || 20) * 1000;
    const events = Array.isArray(playback.events) ? [...playback.events] : [];
    events.sort((a, b) => Number(a.t) - Number(b.t));

    let hg = 0;
    let ag = 0;
    scoreEl.textContent = "0 – 0";
    clockEl.textContent = "1'";
    feed.innerHTML = "";
    setArrow("home", 0.5);

    overlay.hidden = false;
    const started = performance.now();
    let idx = 0;
    let raf = 0;
    let done = false;

    function setArrow(side, pressure = 0.6) {
      const p = Math.max(0.35, Math.min(0.92, Number(pressure) || 0.6));
      // Arrow position: home attack → right side of bar; away attack → left
      const pct = side === "away" ? (1 - p) * 42 + 8 : p * 42 + 50;
      arrow.style.left = `${pct}%`;
      arrow.textContent = side === "away" ? "◀" : "▶";
      arrow.style.color = side === "away" ? awayColor : homeColor;
      arrow.classList.toggle("msim-arrow--pulse", true);
    }

    function pushFeed(ev) {
      const row = document.createElement("div");
      row.className = `msim-ev msim-ev--${escapeHtml(ev.type || "info")}`;
      if (ev.side) row.classList.add(`msim-ev--${ev.side}`);
      row.textContent = ev.text || ev.type || "";
      feed.prepend(row);
    }

    function finish() {
      if (done) return;
      done = true;
      cancelAnimationFrame(raf);
      hg = data?.home_goals ?? hg;
      ag = data?.away_goals ?? ag;
      scoreEl.textContent = `${hg} – ${ag}`;
      clockEl.textContent = "FT";
      setTimeout(() => {
        overlay.hidden = true;
        resolve(data);
      }, 700);
    }

    function tick(now) {
      if (done) return;
      const elapsed = now - started;
      const tSec = elapsed / 1000;

      while (idx < events.length && Number(events[idx].t) <= tSec) {
        const ev = events[idx++];
        if (ev.type === "momentum" || ev.type === "goal" || ev.type === "red") {
          if (ev.side === "home" || ev.side === "away") {
            setArrow(ev.side, ev.pressure);
          }
        }
        if (ev.type === "goal") {
          hg = ev.score_home ?? hg;
          ag = ev.score_away ?? ag;
          scoreEl.textContent = `${hg} – ${ag}`;
          scoreEl.classList.add("msim-score--flash");
          setTimeout(() => scoreEl.classList.remove("msim-score--flash"), 400);
        }
        if (ev.minute != null) clockEl.textContent = `${ev.minute}'`;
        if (ev.type !== "momentum") pushFeed(ev);
        if (ev.type === "fulltime") {
          finish();
          return;
        }
      }

      if (elapsed >= duration) {
        finish();
        return;
      }
      raf = requestAnimationFrame(tick);
    }

    skipBtn.onclick = () => finish();
    raf = requestAnimationFrame(tick);
  });
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Shared CSS for banners + momentum modal. */
export const MATCH_SIM_BANNER_STYLE = `
.match-sim-banner { font-size:13px; color:#bbb; margin:0 0 12px; padding:8px 12px; background:#1a221a; border:1px solid #345; border-radius:6px; }
.match-sim-banner--err { background:#2a1515; border-color:#633; color:#f88; }
.match-sim-on { color:#9fd4b0; font-weight:bold; }
.match-sim-off { color:#f88; font-weight:bold; }
.sim-actions { display:inline-flex; flex-wrap:wrap; gap:6px; align-items:center; }
.btn-link.sim-result-btn, button.sim-result-btn {
  display:inline-block; padding:4px 10px; font-size:12px; font-weight:bold;
  background:#2a5535; color:#cfc; border:1px solid #3a6; border-radius:4px; cursor:pointer;
}
.btn-link.sim-instant-btn { background:#333; border-color:#555; color:#ddd; }
.btn-link.sim-result-btn:disabled, button.sim-result-btn:disabled { opacity:.6; cursor:wait; }
.match-sim-toggle { margin-left:8px; background:#444; color:#eee; border:0; }

.msim-overlay {
  position:fixed; inset:0; z-index:9999; background:rgba(0,0,0,.72);
  display:flex; align-items:center; justify-content:center; padding:16px;
}
.msim-overlay[hidden] { display:none !important; }
.msim-modal {
  width:min(520px, 100%); background:#121212; border:1px solid #333; border-radius:10px;
  padding:16px 18px 14px; box-shadow:0 12px 40px rgba(0,0,0,.55); color:#eee;
}
.msim-head { display:flex; flex-direction:column; gap:6px; margin-bottom:12px; }
.msim-teams {
  display:grid; grid-template-columns:1fr auto 1fr; gap:10px; align-items:center;
  font-weight:700; font-size:15px;
}
.msim-home-name { text-align:left; }
.msim-away-name { text-align:right; }
.msim-score { font-size:22px; font-variant-numeric:tabular-nums; color:#ff9900; min-width:4.5ch; text-align:center; }
.msim-score--flash { transform:scale(1.12); transition:transform .15s ease; }
.msim-clock { font-size:12px; color:#888; text-align:center; }
.msim-pitch { margin:8px 0 12px; }
.msim-bar {
  position:relative; height:36px; border-radius:6px; overflow:hidden;
  border:1px solid #333; display:flex;
}
.msim-home-zone, .msim-away-zone { flex:1; opacity:.9; }
.msim-arrow {
  position:absolute; top:50%; transform:translate(-50%,-50%);
  font-size:22px; font-weight:900; text-shadow:0 1px 3px #000;
  transition:left .35s ease, color .25s ease; pointer-events:none;
}
.msim-arrow--pulse { animation:msimPulse .45s ease; }
@keyframes msimPulse { 0%{transform:translate(-50%,-50%) scale(1)} 40%{transform:translate(-50%,-50%) scale(1.25)} 100%{transform:translate(-50%,-50%) scale(1)} }
.msim-feed {
  max-height:160px; overflow:auto; font-size:13px; line-height:1.45;
  border:1px solid #2a2a2a; border-radius:6px; background:#0d0d0d; padding:8px 10px;
  min-height:72px;
}
.msim-ev { padding:3px 0; border-bottom:1px solid #1c1c1c; color:#ccc; }
.msim-ev--goal { color:#9fd4b0; font-weight:700; }
.msim-ev--red { color:#f88; font-weight:700; }
.msim-ev--yellow { color:#e6c35c; }
.msim-ev--injury { color:#f0a070; }
.msim-ev--fulltime { color:#ff9900; font-weight:700; }
.msim-foot { margin-top:10px; text-align:right; }
.msim-skip { background:#333; color:#ddd; border:0; padding:6px 12px; border-radius:4px; cursor:pointer; }
`;
