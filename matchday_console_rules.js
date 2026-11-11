/**
 * Match Day console rules — settings strip, pitch behaviour, display checks.
 * Shared across Match Day, fixture schedule, match report, Learning GPSL.
 */

const ACK_STORAGE_PREFIX = "gpsl_pitch_ack:";

/** Compact chips shown on arrange / check-in / submit surfaces. */
/** Compact chips — pre-match / personnel / tactics (boosts live under On the pitch). */
export const CONSOLE_DISPLAY_CHIPS = [
  "10-min match",
  "Show Manager",
  "Show Subtactic",
  "Show Squad",
  "No individual instructions",
  "No player dragging",
];

export const CONSOLE_PAUSE_CHIPS = ["PA3 or PA4", "Advanced skill only"];

export const CONSOLE_IN_MATCH_CHIPS = [
  "Single Red/Blue from 80'",
  "Double Red/Blue from 90'",
];

export const PITCH_BEHAVIOUR_ITEMS = [
  "NO DOGSO",
  "NO TIMEWASTING",
  "NO MATCH MANIPULATION",
];

/**
 * How this cup fixture is played.
 * Super8 and Bowl quarter-finals are the only two-leg ties.
 * @param {object} [fx]
 * @returns {"single"|"two-first"|"two-second"|"two"|null}
 */
export function cupFixtureKind(fx) {
  if (!fx || String(fx.competition_type || "").toLowerCase() !== "cup") return null;
  const code = String(fx.cup_code || "").toLowerCase();
  const round = Number(fx.cup_round);
  const hasLeg = fx.cup_leg != null && fx.cup_leg !== "";
  const leg = hasLeg ? Number(fx.cup_leg) : null;
  const twoLegRound = (code === "super8" || code === "bowl") && round === 1;
  if (leg === 2) return "two-second";
  if (twoLegRound && leg === 1) return "two-first";
  if (twoLegRound && leg == null) return "two";
  return "single";
}

/** Owner-facing switch line for one cup kind. */
export function cupSwitchNote(kind) {
  if (kind === "two-first") {
    return "1st leg: same as a league match. Extra Time off, Penalties off. A draw stands.";
  }
  if (kind === "two-second") {
    return "2nd leg: same as a league match. Extra Time off, Penalties off. If the tie is level on aggregate, play a 5-minute match with Penalties on and Extra Time off. That match is the extra time.";
  }
  if (kind === "two") {
    return "Two-leg quarter-final: both legs are the same as a league match, Extra Time and Penalties off. If level on aggregate after the 2nd leg, play a 5-minute match with Penalties on and Extra Time off. That match is the extra time.";
  }
  if (kind === "single") {
    return "One-leg cup: same as a league match, with Extra Time and Penalties switched on.";
  }
  return "";
}

/**
 * @param {{ isCup?: boolean, isTwoLegFirst?: boolean, isTwoLegSecond?: boolean, levelOnAggregate?: boolean, kind?: string|null }} [opts]
 */
export function cupConsoleBadge(opts = {}) {
  let kind = opts.kind || null;
  if (!kind) {
    if (opts.isTwoLegFirst) kind = "two-first";
    else if (opts.isTwoLegSecond) kind = "two-second";
    else if (opts.isCup) kind = "single";
  }
  if (kind === "two-second" && opts.levelOnAggregate) kind = "two-decider";
  if (kind === "two-first") {
    return {
      label: "Cup · 1st leg",
      detail: "Same as league · Extra Time off · Penalties off · a draw stands",
    };
  }
  if (kind === "two-decider") {
    return {
      label: "Cup · 5 min",
      detail: "Penalties on · Extra Time off · this match is the extra time · goals count with both legs",
    };
  }
  if (kind === "two-second" || kind === "two") {
    return {
      label: "Cup · 2nd leg",
      detail: "Same as league · Extra Time off · Penalties off · if level on aggregate, a 5-minute match with Penalties on and Extra Time off",
    };
  }
  if (kind === "single") {
    return {
      label: "Cup · 1 leg",
      detail: "Same as league · Extra Time on · Penalties on",
    };
  }
  return null;
}

/**
 * Compact always-on strip HTML.
 * @param {{
 *   isCup?: boolean,
 *   isTwoLegFirst?: boolean,
 *   isTwoLegSecond?: boolean,
 *   levelOnAggregate?: boolean,
 *   kind?: string|null,
 *   className?: string,
 *   chips?: boolean,  // false = cup badge only (no duplicate of Display checks)
 * }} [opts]
 */
export function matchConsoleStripHtml(opts = {}) {
  const showChips = opts.chips !== false;
  const cup = cupConsoleBadge(opts);
  const chips = showChips
    ? [
        ...CONSOLE_DISPLAY_CHIPS,
        ...CONSOLE_PAUSE_CHIPS,
        ...CONSOLE_IN_MATCH_CHIPS,
      ]
        .map((c) => `<span class="md-console-chip">${escapeHtml(c)}</span>`)
        .join("")
    : "";
  const cupHtml = cup
    ? `<span class="md-console-cup" title="${escapeHtml(cup.detail)}"><b>${escapeHtml(
        cup.label
      )}</b> · ${escapeHtml(cup.detail)}</span>`
    : "";
  if (!showChips && !cupHtml) return "";
  return `
    <div class="md-console-strip ${opts.className || ""}" role="note" aria-label="Match console settings">
      <div class="md-console-strip-label">${showChips ? "Console" : "Cup"}</div>
      ${chips ? `<div class="md-console-chips">${chips}</div>` : ""}
      ${cupHtml}
    </div>`;
}

/**
 * Pitch behaviour block + optional once-per-fixture acknowledgement.
 * @param {{ fixtureId?: string|null, requireAck?: boolean, hideItems?: boolean }} [opts]
 */
export function pitchBehaviourPanelHtml(opts = {}) {
  const hideItems = !!opts.hideItems;
  const items = hideItems
    ? ""
    : `<ul class="md-pitch-behaviour-list">${PITCH_BEHAVIOUR_ITEMS.map(
        (t) => `<li><b>${escapeHtml(t)}</b></li>`
      ).join("")}</ul>`;
  const fid = opts.fixtureId ? String(opts.fixtureId) : "";
  const already = fid && hasPitchAck(fid);
  const ackBlock =
    opts.requireAck && fid && !already
      ? `<label class="md-pitch-ack-label">
           <input type="checkbox" class="md-pitch-ack-input" data-fixture-id="${escapeHtml(
             fid
           )}" />
           I’ve set the console correctly and will follow pitch behaviour for this fixture.
         </label>`
      : opts.requireAck && fid && already
        ? `<p class="md-pitch-ack-done">Pitch behaviour acknowledged for this fixture.</p>`
        : "";
  if (hideItems && !ackBlock) return "";
  return `
    <div class="md-pitch-behaviour${hideItems ? " md-pitch-behaviour--ack" : ""}" role="note" aria-label="On the pitch behaviour">
      ${hideItems ? "" : `<div class="md-pitch-behaviour-title">On the pitch</div>`}
      ${items}
      ${ackBlock}
    </div>`;
}

export function hasPitchAck(fixtureId) {
  if (!fixtureId || typeof localStorage === "undefined") return false;
  try {
    return localStorage.getItem(ACK_STORAGE_PREFIX + String(fixtureId)) === "1";
  } catch {
    return false;
  }
}

export function setPitchAck(fixtureId) {
  if (!fixtureId || typeof localStorage === "undefined") return;
  try {
    localStorage.setItem(ACK_STORAGE_PREFIX + String(fixtureId), "1");
  } catch {
    /* ignore quota */
  }
}

/**
 * Wire checkbox listeners inside a root (call after injecting HTML).
 * @param {ParentNode} root
 * @param {{ onAck?: (fixtureId: string) => void }} [opts]
 */
export function wirePitchAck(root, opts = {}) {
  if (!root) return;
  root.querySelectorAll(".md-pitch-ack-input").forEach((el) => {
    el.addEventListener("change", () => {
      if (!el.checked) return;
      const fid = el.getAttribute("data-fixture-id");
      if (!fid) return;
      setPitchAck(fid);
      opts.onAck?.(fid);
      const panel = el.closest(".md-pitch-behaviour");
      if (panel) {
        const label = panel.querySelector(".md-pitch-ack-label");
        if (label) {
          label.replaceWith(
            Object.assign(document.createElement("p"), {
              className: "md-pitch-ack-done",
              textContent: "Pitch behaviour acknowledged for this fixture.",
            })
          );
        }
      }
    });
  });
}

/** Prematch checklist for match report (soft honesty items). */
export function prematchConsoleChecklistHtml(opts = {}) {
  const cupLine = cupSwitchNote(cupFixtureKind(opts.fixture));
  const rows = [
    [
      "Pre-Match Settings",
      "10 minutes | Injuries off | Substitutes 5 | Sub intervals 3 | Form Random",
    ],
    ...(cupLine ? [["Cup", cupLine]] : []),
    [
      "Personnel",
      "Show Manager · Show Subtactic · Show Squad · Player instructions Blank (blocked if used)",
    ],
    [
      "Tactics",
      "Sub tactic and Fluid are default Konami formations, set before the match. No dragging. Staff confirm a video report: offender won or drew → replay; opponent won → result stands; 2 or more drags → −1 point.",
    ],
    ["Pause before KO", "PA3 or PA4 · Advanced skill only"],
    [
      "On the pitch",
      [
        "Single Red/Blue from 80'",
        "Double Red/Blue from 90'",
        ...PITCH_BEHAVIOUR_ITEMS.map((s) => s.replace(/^NO /, "No ")),
      ].join(" · "),
    ],
    [
      "Stadium",
      "Licensed Club = Licensed Stadium · else Konami (DECORATED as home-kit colours, borders only, real-life name)",
    ],
  ]
    .map(
      ([k, v]) =>
        `<li><span class="mr-console-k">${escapeHtml(k)}:</span> <span class="mr-console-v">${escapeHtml(
          v
        )}</span></li>`
    )
    .join("");
  return `
    <div class="mr-prematch-check mr-console-check">
      <div class="mr-prematch-check-title">Prematch console checklist</div>
      <p class="mr-prematch-check-sub">Show all on recording</p>
      <p class="mr-prematch-check-note">Confirm these in eFootball before kick-off (not verified by the site).</p>
      <ul class="mr-console-list">${rows}</ul>
    </div>`;
}

/** Rules-card content for Match Day submit panel. */
export function getMatchdayConsoleRulesCards() {
  return {
    title: "Display checks",
    cards: [
      {
        heading: "Pre-Match Settings",
        tip: "Same room settings as a league match. Cup ties only change Extra Time and Penalties.",
        items: [
          "<b>10-minute</b> match, <b>Injuries off</b>, <b>5 substitutes</b>, <b>3 sub intervals</b>, <b>Form Random</b>.",
          "<b>One-leg cup:</b> same match, with <b>Extra Time</b> and <b>Penalties</b> switched on.",
          "<b>Two-leg cup</b> (Super8 and Bowl quarter-finals): both legs are the same as league. <b>Extra Time</b> and <b>Penalties</b> stay off. A draw stands.",
          "If the two-leg tie is <b>level on aggregate</b> after the 2nd leg, play a third <b>5-minute</b> match with <b>Penalties on</b> and <b>Extra Time off</b>. That match is the extra time. Still level, the shootout decides it. Its goals count with both legs.",
        ],
      },
      {
        heading: "Stadium",
        tip: "Licensed club = real stadium. Everyone else = Konami stadium, home-kit colours, real-life name.",
        items: [
          "<b>Licensed clubs only</b> may use their real eFootball stadium.",
          "<b>Non-licensed clubs</b> must use the <b>Konami stadium</b>.",
          "<b>Konami stadium:</b> decorate in <b>home kit</b> colours; <b>standard borders only</b> (no statues, Halloween, or other accessories); name it as the club’s <b>correct real-life stadium</b>.",
          `See <a href="stadium.html">Stadium</a> and <a href="learning_gpsl.html#matchday">Learning GPSL</a>.`,
        ],
      },
      {
        heading: "Personnel",
        tip: "Show Manager, Subtactic and Squad on the recording for the whole match.",
        items: [
          "<b>Show Manager</b>, <b>Show Subtactic</b>, and <b>Show Squad</b> on — they must stay visible on the match recording or you can be reported and fined.",
        ],
      },
      {
        heading: "Tactics",
        tip: "Sub tactic and Fluid are set before the eFootball match. No dragging. Staff confirm the video report before anything changes.",
        items: [
          "<b>Player instructions</b> blank (blocked if used — ₿10m).",
          "<b>Sub tactic</b> and <b>Fluid</b> must be a <b>default Konami formation</b>, set up <b>before</b> the match is played.",
          "<b>No dragging players</b> at all on matchday.",
          "Report drags from the Fixtures <b>R</b> button and say how many times. <b>Nothing happens until staff approve.</b>",
          "If the offender <b>won or drew</b>, the match is <b>replayed</b>. If the <b>opponent won</b>, the result <b>stands</b>. <b>2 or more drags</b> in that match also deduct <b>1 league point</b>.",
        ],
      },
      {
        heading: "Pause before kick-off",
        tip: "Pause and show PA3 or PA4 plus Advanced skill before kick-off.",
        items: [
          "Show <b>PA level</b> — <b>PA3</b> or <b>PA4</b> only.",
          "<b>Advanced</b> skill setting only.",
        ],
      },
      {
        heading: "On the pitch",
        tip: "Single Red/Blue from 80'. Double from 90'. No DOGSO, timewasting or match manipulation.",
        items: [
          "<b>Single Red or Blue</b> only from the <b>80th minute</b> (before 80' = fine).",
          "<b>Double Red/Blue</b> only from the <b>90th minute</b> (before 90' = fine).",
          ...PITCH_BEHAVIOUR_ITEMS.map((t) => `<b>${t}</b>`),
        ],
      },
    ],
  };
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
