/**
 * Match Day console rules — settings strip, pitch behaviour, display checks.
 * Shared across Match Day, fixture schedule, match report, Learning GPSL.
 */

const ACK_STORAGE_PREFIX = "gpsl_pitch_ack:";

/** Compact chips shown on arrange / check-in / submit surfaces. */
export const CONSOLE_DISPLAY_CHIPS = [
  "10-min match",
  "Show Manager",
  "Show Subtactic",
  "Show Squad",
  "Fluid Formation Off",
];

export const CONSOLE_PAUSE_CHIPS = ["PA3 or PA4", "Advanced skill only"];

export const PITCH_BEHAVIOUR_ITEMS = [
  "NO DOGSO",
  "NO TIMEWASTING",
  "NO MATCH MANIPULATION",
];

/**
 * @param {{ isCup?: boolean, isTwoLegFirst?: boolean, isTwoLegSecond?: boolean, levelOnAggregate?: boolean }} [opts]
 */
export function cupConsoleBadge(opts = {}) {
  if (!opts.isCup) return null;
  if (opts.isTwoLegFirst) {
    return {
      label: "2-leg · 1st leg",
      detail: "90 min only — draws OK · no ET / pens",
    };
  }
  if (opts.isTwoLegSecond) {
    if (opts.levelOnAggregate) {
      return {
        label: "2-leg · level agg",
        detail: "5-min match · then ET + pens · scores combine with both legs",
      };
    }
    return {
      label: "2-leg · 2nd leg",
      detail: "Default FT only · if level on aggregate → 5-min + ET + pens",
    };
  }
  return {
    label: "Cup KO",
    detail: "Extra time + penalties if level after 90",
  };
}

/**
 * Compact always-on strip HTML.
 * @param {{ isCup?: boolean, isTwoLegFirst?: boolean, isTwoLegSecond?: boolean, levelOnAggregate?: boolean, className?: string }} [opts]
 */
export function matchConsoleStripHtml(opts = {}) {
  const cup = cupConsoleBadge(opts);
  const chips = [...CONSOLE_DISPLAY_CHIPS, ...CONSOLE_PAUSE_CHIPS]
    .map((c) => `<span class="md-console-chip">${escapeHtml(c)}</span>`)
    .join("");
  const cupHtml = cup
    ? `<span class="md-console-cup" title="${escapeHtml(cup.detail)}"><b>${escapeHtml(
        cup.label
      )}</b> · ${escapeHtml(cup.detail)}</span>`
    : "";
  return `
    <div class="md-console-strip ${opts.className || ""}" role="note" aria-label="Match console settings">
      <div class="md-console-strip-label">Console</div>
      <div class="md-console-chips">${chips}</div>
      ${cupHtml}
    </div>`;
}

/**
 * Pitch behaviour block + optional once-per-fixture acknowledgement.
 * @param {{ fixtureId?: string|null, requireAck?: boolean }} [opts]
 */
export function pitchBehaviourPanelHtml(opts = {}) {
  const items = PITCH_BEHAVIOUR_ITEMS.map(
    (t) => `<li><b>${escapeHtml(t)}</b></li>`
  ).join("");
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
  return `
    <div class="md-pitch-behaviour" role="note" aria-label="On the pitch behaviour">
      <div class="md-pitch-behaviour-title">On the pitch</div>
      <ul class="md-pitch-behaviour-list">${items}</ul>
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
export function prematchConsoleChecklistHtml() {
  const rows = [
    ["Match length", "10 minutes (all other settings default)"],
    [
      "Display",
      "Show Manager · Show Subtactic · Show Squad · Fluid Formation Off",
    ],
    ["Pause before KO", "PA3 or PA4 · Advanced skill only"],
    [
      "On the pitch",
      PITCH_BEHAVIOUR_ITEMS.map((s) => s.replace(/^NO /, "No ")).join(" · "),
    ],
  ]
    .map(
      ([k, v]) =>
        `<li><span class="mr-console-k">${escapeHtml(k)}</span><span class="mr-console-v">${escapeHtml(
          v
        )}</span></li>`
    )
    .join("");
  return `
    <div class="mr-prematch-check mr-console-check">
      <div class="mr-prematch-check-title">Prematch console checklist</div>
      <p class="mr-prematch-check-note">Confirm these in eFootball before kick-off (not verified by the site).</p>
      <ul class="mr-console-list">${rows}</ul>
    </div>`;
}

/** Rules-card content for Match Day submit panel. */
export function getMatchdayConsoleRulesCards() {
  return {
    cards: [
      {
        heading: "Display checks",
        items: [
          "<b>10-minute</b> match (all other settings default).",
          "<b>Show Manager</b>, <b>Show Subtactic</b>, and <b>Show Squad</b> on.",
          "<b>Fluid Formation</b> set to <b>Off</b> (Konami fluid formations are not allowed).",
          "<b>Cup knockout (1-leg):</b> Extra Time and Penalties if level after 90.",
          "<b>2-legged cups:</b> default 90 min only (no ET/pens). If level on aggregate after the 2nd leg — play a <b>5-minute</b> match with ET + pens; scores combine with both legs to decide the winner.",
        ],
      },
      {
        heading: "Pause before kick-off",
        items: [
          "Show <b>PA level</b> — <b>PA3</b> or <b>PA4</b> only.",
          "<b>Advanced</b> skill setting only.",
        ],
      },
      {
        heading: "On the pitch",
        items: PITCH_BEHAVIOUR_ITEMS.map((t) => `<b>${t}</b>`),
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
