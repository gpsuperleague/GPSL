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
    const detail = [error.message, error.details, error.hint].filter(Boolean).join(" — ");
    const err = new Error(detail || "Simulation failed");
    err.code = error.code;
    throw err;
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
        <div class="msim-clock" id="msimClock">0'</div>
        <div class="msim-phase" id="msimPhase">1st half</div>
      </div>
      <div class="msim-ht" id="msimHt" hidden>
        <div class="msim-ht-label">HALF TIME</div>
        <div class="msim-ht-score" id="msimHtScore">0 – 0</div>
      </div>
      <div class="msim-pitch">
        <div class="msim-bar" id="msimBar">
          <div class="msim-home-zone" id="msimHomeZone"></div>
          <div class="msim-away-zone" id="msimAwayZone"></div>
          <div class="msim-arrow" id="msimArrow" aria-hidden="true">▶</div>
        </div>
      </div>
      <div class="msim-feed" id="msimFeed">
        <div class="msim-feed-col msim-feed-home" id="msimFeedHome"></div>
        <div class="msim-feed-col msim-feed-away" id="msimFeedAway"></div>
        <div class="msim-feed-center" id="msimFeedCenter"></div>
      </div>
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
    const phaseEl = overlay.querySelector("#msimPhase");
    const htEl = overlay.querySelector("#msimHt");
    const htScoreEl = overlay.querySelector("#msimHtScore");
    const arrow = overlay.querySelector("#msimArrow");
    const homeZone = overlay.querySelector("#msimHomeZone");
    const awayZone = overlay.querySelector("#msimAwayZone");
    const skipBtn = overlay.querySelector("#msimSkip");

    // Ensure HT / phase nodes exist on older overlay markup
    if (!phaseEl) {
      const clock = overlay.querySelector("#msimClock");
      const phase = document.createElement("div");
      phase.className = "msim-phase";
      phase.id = "msimPhase";
      clock?.after(phase);
    }
    if (!htEl) {
      const pitch = overlay.querySelector(".msim-pitch");
      const ht = document.createElement("div");
      ht.className = "msim-ht";
      ht.id = "msimHt";
      ht.hidden = true;
      ht.innerHTML = `<div class="msim-ht-label">HALF TIME</div><div class="msim-ht-score" id="msimHtScore">0 – 0</div>`;
      pitch?.before(ht);
    }
    const phaseNode = overlay.querySelector("#msimPhase");
    const htNode = overlay.querySelector("#msimHt");
    const htScoreNode = overlay.querySelector("#msimHtScore");

    const homeColor = data?.colours?.home?.primary || "#3b82f6";
    const awayColor = data?.colours?.away?.primary || "#ef4444";
    homeZone.style.background = `linear-gradient(90deg, ${homeColor}, ${homeColor}99)`;
    awayZone.style.background = `linear-gradient(90deg, ${awayColor}99, ${awayColor})`;

    overlay.querySelector("#msimHomeName").textContent =
      labels.homeName || data?.home_name || data?.home_club || "Home";
    overlay.querySelector("#msimAwayName").textContent =
      labels.awayName || data?.away_name || data?.away_club || "Away";

    const playback = data?.playback || {};
    // Total graphic length: play both halves + HT pause
    const htPauseSec = 3;
    const playBudgetSec = Math.max(10, Number(playback.duration_sec) || 20);
    const totalSec = playBudgetSec + htPauseSec;

    const add1 = 1 + Math.floor(Math.random() * 5); // 1–5
    const add2 = 1 + Math.floor(Math.random() * 5);
    const fhMins = 45 + add1;
    const shMins = 45 + add2;
    const matchMins = fhMins + shMins;
    const fhPlaySec = playBudgetSec * (fhMins / matchMins);
    const shPlaySec = playBudgetSec - fhPlaySec;
    const fhEndSec = fhPlaySec;
    const htEndSec = fhEndSec + htPauseSec;
    const ftSec = htEndSec + shPlaySec;

    const rawEvents = Array.isArray(playback.events) ? [...playback.events] : [];
    // Remap events onto half-aware timeline by match minute
    const events = rawEvents
      .filter((e) => e && e.type !== "kickoff")
      .map((e) => {
        let minute = Number(e.minute);
        if (!Number.isFinite(minute)) {
          const t0 = Number(e.t) || 0;
          const dur0 = Math.max(1, Number(playback.duration_sec) || 20);
          minute = Math.max(1, Math.min(90 + add2, Math.round((t0 / dur0) * (90 + add2))));
        }
        // Clamp into match span (0..fhMins for 1H, 45..90+add2 for 2H)
        if (minute <= 45) {
          // keep; stoppage shown via clock when >45 in FH remap below
        } else if (minute > 45 && minute < 46) {
          minute = 45;
        }
        // Spread old 46-90 into second half; stoppage 90+ into add2
        let at = 0;
        if (e.type === "fulltime") {
          at = ftSec;
        } else if (minute <= 45) {
          // Scale 0-45 across first 45 mins of FH play (before added time window)
          const inReg = minute / 45;
          at = inReg * (45 / fhMins) * fhPlaySec;
        } else if (minute <= 90) {
          const shProg = (minute - 45) / 45;
          at = htEndSec + shProg * (45 / shMins) * shPlaySec;
        } else {
          // 90+ stoppage
          const stop = Math.min(add2, minute - 90);
          at = htEndSec + ((45 + stop) / shMins) * shPlaySec;
        }
        // First-half stoppage events (minute 45 with late t): place into FH added time
        if (e.type !== "fulltime" && minute === 45 && Number(e.t) > (Number(playback.duration_sec) || 20) * 0.45) {
          at = fhPlaySec * (45 / fhMins) + (fhPlaySec * (add1 / fhMins)) * 0.5;
        }
        return { ...e, minute, at };
      })
      .sort((a, b) => a.at - b.at);

    // Inject synthetic stoppage / HT markers (display only)
    // (clock handles added-time labels; HT banner from phase)

    let hg = 0;
    let ag = 0;
    let htShown = false;
    scoreEl.textContent = "0 – 0";
    clockEl.textContent = "0'";
    if (phaseNode) phaseNode.textContent = "1st half";
    if (htNode) htNode.hidden = true;
    let add1Announced = false;
    let add2Announced = false;

    if (!overlay.querySelector("#msimFeedHome")) {
      feed.innerHTML = `
        <div class="msim-feed-col msim-feed-home" id="msimFeedHome"></div>
        <div class="msim-feed-col msim-feed-away" id="msimFeedAway"></div>
        <div class="msim-feed-center" id="msimFeedCenter"></div>
      `;
    }
    const feedHome = overlay.querySelector("#msimFeedHome");
    const feedAway = overlay.querySelector("#msimFeedAway");
    const feedCenter = overlay.querySelector("#msimFeedCenter");
    feedHome.innerHTML = "";
    feedAway.innerHTML = "";
    feedCenter.innerHTML = "";

    /** @type {{ home: HTMLElement|null, away: HTMLElement|null }} */
    const lastGoalBlock = { home: null, away: null };

    let momentum = 0.5;
    let target = 0.55;
    let surgeUntil = 0;
    let lastSide = "home";

    overlay.hidden = false;
    const started = performance.now();
    let idx = 0;
    let raf = 0;
    let done = false;
    let prevNow = started;

    function eventTarget(ev) {
      const pressure = Math.max(0.35, Math.min(0.95, Number(ev.pressure) || 0.7));
      if (ev.side === "away") return (1 - pressure) * 0.42;
      if (ev.side === "home") return 0.58 + pressure * 0.38;
      return 0.5;
    }

    function paintArrow(m) {
      const pct = 8 + m * 84;
      const homeAttack = m >= 0.5;
      arrow.style.left = `${pct}%`;
      if (homeAttack !== (lastSide === "home")) {
        arrow.classList.remove("msim-arrow--pulse");
        void arrow.offsetWidth;
        arrow.classList.add("msim-arrow--pulse");
      }
      lastSide = homeAttack ? "home" : "away";
      arrow.textContent = homeAttack ? "▶" : "◀";
      arrow.style.color = homeAttack ? homeColor : awayColor;
    }

    function formatClock(matchMin, phase) {
      if (phase === "ht") return "HT";
      if (phase === "ft") return "FT";
      if (phase === "fh") {
        if (matchMin <= 45) return `${Math.max(0, Math.floor(matchMin))}'`;
        const extra = Math.min(add1, Math.max(1, Math.ceil(matchMin - 45)));
        return `45+${extra}'`;
      }
      // second half
      if (matchMin <= 90) return `${Math.max(45, Math.floor(matchMin))}'`;
      const extra = Math.min(add2, Math.max(1, Math.ceil(matchMin - 90)));
      return `90+${extra}'`;
    }

    function timelineState(tSec) {
      if (tSec < fhEndSec) {
        const p = tSec / fhPlaySec;
        const matchMin = p * fhMins;
        return { phase: "fh", matchMin, playing: true };
      }
      if (tSec < htEndSec) {
        return { phase: "ht", matchMin: 45, playing: false };
      }
      if (tSec < ftSec) {
        const p = (tSec - htEndSec) / shPlaySec;
        const matchMin = 45 + p * shMins;
        return { phase: "sh", matchMin, playing: true };
      }
      return { phase: "ft", matchMin: 90 + add2, playing: false };
    }

    function shortEventLabel(ev) {
      const minLabel =
        ev.minute != null
          ? ev.minute > 90
            ? `90+${Math.min(add2, ev.minute - 90)}' `
            : ev.minute > 45 && ev.minute <= 45 + add1 && ev.at < htEndSec
              ? `45+${Math.min(add1, Math.max(1, Math.round(ev.minute - 45) || 1))}' `
              : `${ev.minute}' `
          : "";
      const name = ev.player || "";
      if (ev.type === "goal") return `${minLabel}${name || "Goal"}`;
      if (ev.type === "assist") return name ? `a ${name}` : "assist";
      if (ev.type === "yellow") return `${minLabel}Y ${name || "Yellow"}`;
      if (ev.type === "red") return `${minLabel}R ${name || "Red"}`;
      if (ev.type === "injury") return `${minLabel}Inj ${name || "Injury"}`;
      if (ev.type === "halftime") return ev.text || "HALF TIME";
      if (ev.type === "fulltime") return ev.text || "Full time";
      return ev.text || ev.type || "";
    }

    function colFor(side) {
      if (side === "away") return feedAway;
      if (side === "home") return feedHome;
      return feedCenter;
    }

    function pushFeed(ev) {
      const side = ev.side === "away" ? "away" : ev.side === "home" ? "home" : null;

      if (ev.type === "assist" && side) {
        const block = lastGoalBlock[side];
        if (block) {
          let assistEl = block.querySelector(".msim-ev-assist");
          if (!assistEl) {
            assistEl = document.createElement("div");
            assistEl.className = "msim-ev-assist";
            block.appendChild(assistEl);
          }
          assistEl.textContent = shortEventLabel(ev);
          return;
        }
      }

      if (ev.type === "fulltime" || ev.type === "halftime" || !side) {
        const row = document.createElement("div");
        row.className = `msim-ev msim-ev--${escapeHtml(ev.type || "info")} msim-ev--center`;
        row.textContent = shortEventLabel(ev);
        feedCenter.prepend(row);
        return;
      }

      if (ev.type === "goal") {
        const block = document.createElement("div");
        block.className = `msim-goal-block msim-ev--${side}`;
        const goalEl = document.createElement("div");
        goalEl.className = "msim-ev msim-ev--goal";
        goalEl.textContent = shortEventLabel(ev);
        block.appendChild(goalEl);
        colFor(side).prepend(block);
        lastGoalBlock[side] = block;

        const next = events[idx];
        if (next && next.type === "assist" && next.side === side) {
          idx += 1;
          const assistEl = document.createElement("div");
          assistEl.className = "msim-ev-assist";
          assistEl.textContent = shortEventLabel(next);
          block.appendChild(assistEl);
        }
        return;
      }

      const row = document.createElement("div");
      row.className = `msim-ev msim-ev--${escapeHtml(ev.type || "info")} msim-ev--${side}`;
      row.textContent = shortEventLabel(ev);
      colFor(side).prepend(row);
    }

    function showHalfTime() {
      if (htShown) return;
      htShown = true;
      if (htNode) htNode.hidden = false;
      if (htScoreNode) htScoreNode.textContent = `${hg} – ${ag}`;
      if (phaseNode) phaseNode.textContent = "Half time";
      clockEl.textContent = "HT";
      pushFeed({
        type: "halftime",
        text: `HALF TIME ${hg} – ${ag}`,
      });
    }

    function hideHalfTime() {
      if (htNode) htNode.hidden = true;
      if (phaseNode) phaseNode.textContent = "2nd half";
    }

    function updatePhaseLabel(state) {
      if (!phaseNode) return;
      if (state.phase === "ht") {
        phaseNode.textContent = "Half time";
        return;
      }
      if (state.phase === "ft") {
        phaseNode.textContent = "Full time";
        return;
      }
      if (state.phase === "fh") {
        // Announce added time from 40' (5 mins before end of regulation)
        if (state.matchMin >= 40) {
          phaseNode.textContent = `1st half · +${add1} mins`;
          if (!add1Announced) {
            add1Announced = true;
            pushFeed({ type: "halftime", text: `Added time +${add1}` });
          }
        } else {
          phaseNode.textContent = "1st half";
        }
        return;
      }
      if (state.phase === "sh") {
        if (state.matchMin >= 85) {
          phaseNode.textContent = `2nd half · +${add2} mins`;
          if (!add2Announced) {
            add2Announced = true;
            pushFeed({ type: "halftime", text: `Added time +${add2}` });
          }
        } else {
          phaseNode.textContent = "2nd half";
        }
      }
    }

    function finish() {
      if (done) return;
      done = true;
      cancelAnimationFrame(raf);
      hg = data?.home_goals ?? hg;
      ag = data?.away_goals ?? ag;
      scoreEl.textContent = `${hg} – ${ag}`;
      clockEl.textContent = "FT";
      if (phaseNode) phaseNode.textContent = "Full time";
      if (htNode) htNode.hidden = true;
      setTimeout(() => {
        overlay.hidden = true;
        resolve(data);
      }, 900);
    }

    function tick(now) {
      if (done) return;
      const elapsed = now - started;
      const tSec = elapsed / 1000;
      const dt = Math.min(0.05, (now - prevNow) / 1000);
      prevNow = now;

      const state = timelineState(tSec);

      if (state.phase === "ht") {
        showHalfTime();
      } else if (state.phase === "sh" && htShown) {
        hideHalfTime();
      }
      updatePhaseLabel(state);

      while (idx < events.length && Number(events[idx].at) <= tSec) {
        const ev = events[idx++];
        if (ev.type === "momentum") {
          if (ev.side === "home" || ev.side === "away") {
            target = eventTarget(ev);
            surgeUntil = tSec + 0.85;
            momentum += (target - momentum) * 0.35;
          }
          continue;
        }
        if (
          (ev.type === "goal" || ev.type === "red") &&
          (ev.side === "home" || ev.side === "away")
        ) {
          target = eventTarget(ev);
          surgeUntil = tSec + (ev.type === "goal" ? 1.4 : 0.85);
          momentum += (target - momentum) * (ev.type === "goal" ? 0.55 : 0.35);
        }
        if (ev.type === "goal") {
          hg = ev.score_home ?? hg;
          ag = ev.score_away ?? ag;
          scoreEl.textContent = `${hg} – ${ag}`;
          scoreEl.classList.add("msim-score--flash");
          setTimeout(() => scoreEl.classList.remove("msim-score--flash"), 400);
        }
        if (ev.type !== "momentum") pushFeed(ev);
        if (ev.type === "fulltime") {
          finish();
          return;
        }
      }

      if (state.playing) {
        const wave =
          Math.sin(tSec * 2.4) * 0.14 +
          Math.sin(tSec * 5.1 + 1.3) * 0.08 +
          Math.sin(tSec * 0.9 + 0.4) * 0.1;
        const bias = 0.5 + Math.sin(tSec * 0.55) * 0.12;
        let liveTarget = bias + wave;
        if (tSec < surgeUntil) {
          const blend = Math.min(1, (surgeUntil - tSec) / 0.9);
          liveTarget = target * (0.55 + 0.35 * blend) + liveTarget * (0.45 - 0.25 * blend);
        }
        liveTarget = Math.max(0.06, Math.min(0.94, liveTarget));
        const chase = tSec < surgeUntil ? 7.5 : 4.2;
        momentum += (liveTarget - momentum) * (1 - Math.exp(-chase * dt));
        momentum = Math.max(0.04, Math.min(0.96, momentum));
        paintArrow(momentum);
        clockEl.textContent = formatClock(state.matchMin, state.phase);
      } else if (state.phase === "ht") {
        clockEl.textContent = "HT";
      }

      if (tSec >= ftSec) {
        finish();
        return;
      }
      raf = requestAnimationFrame(tick);
    }

    paintArrow(momentum);
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
.msim-clock { font-size:14px; color:#ff9900; text-align:center; font-weight:700; font-variant-numeric:tabular-nums; }
.msim-phase { font-size:11px; color:#888; text-align:center; margin-top:2px; }
.msim-ht {
  margin:8px 0 10px; padding:12px 10px; text-align:center;
  border:1px solid #445; border-radius:8px; background:#161a22;
}
.msim-ht[hidden] { display:none !important; }
.msim-ht-label { font-size:12px; font-weight:800; letter-spacing:.08em; color:#9ab; }
.msim-ht-score { font-size:26px; font-weight:800; color:#ff9900; margin-top:4px; font-variant-numeric:tabular-nums; }
.msim-ev--halftime { color:#9ab; font-weight:700; }
.msim-pitch { margin:8px 0 12px; }
.msim-bar {
  position:relative; height:36px; border-radius:6px; overflow:hidden;
  border:1px solid #333; display:flex;
}
.msim-home-zone, .msim-away-zone { flex:1; opacity:.9; }
.msim-arrow {
  position:absolute; top:50%; transform:translate(-50%,-50%);
  font-size:24px; font-weight:900; text-shadow:0 1px 4px #000;
  transition:color .15s ease; pointer-events:none; will-change:left;
}
.msim-arrow--pulse { animation:msimPulse .4s ease; }
@keyframes msimPulse {
  0%{transform:translate(-50%,-50%) scale(1)}
  35%{transform:translate(-50%,-50%) scale(1.35)}
  100%{transform:translate(-50%,-50%) scale(1)}
}
.msim-feed {
  display:grid; grid-template-columns:1fr 1fr; gap:8px 12px; align-items:start;
  max-height:200px; overflow:auto; font-size:13px; line-height:1.35;
  border:1px solid #2a2a2a; border-radius:6px; background:#0d0d0d; padding:8px 10px;
  min-height:88px; position:relative;
}
.msim-feed-col { display:flex; flex-direction:column; gap:6px; min-width:0; }
.msim-feed-home { text-align:left; }
.msim-feed-away { text-align:right; }
.msim-feed-center {
  grid-column:1 / -1; text-align:center; display:flex; flex-direction:column; gap:4px;
}
.msim-goal-block { display:flex; flex-direction:column; gap:1px; }
.msim-feed-away .msim-goal-block { align-items:flex-end; }
.msim-feed-home .msim-goal-block { align-items:flex-start; }
.msim-ev { padding:2px 0; color:#ccc; }
.msim-ev--goal { color:#9fd4b0; font-weight:700; font-size:13px; }
.msim-ev-assist {
  color:#8aa; font-size:10px; font-weight:500; line-height:1.2; opacity:.9;
  margin-top:0; padding:0 2px 2px;
}
.msim-feed-away .msim-ev-assist { text-align:right; }
.msim-feed-home .msim-ev-assist { text-align:left; }
.msim-ev--red { color:#f88; font-weight:700; }
.msim-ev--yellow { color:#e6c35c; }
.msim-ev--injury { color:#f0a070; }
.msim-ev--fulltime { color:#ff9900; font-weight:700; }
.msim-ev--center { width:100%; }
.msim-foot { margin-top:10px; text-align:right; }
.msim-skip { background:#333; color:#ddd; border:0; padding:6px 12px; border-radius:4px; cursor:pointer; }
`;
