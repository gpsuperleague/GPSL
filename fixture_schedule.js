import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS, formatFixtureCompetition } from "./competition.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  loadScheduleContext,
  proposeKickoff,
  acceptProposal,
  checkInToFixture,
  loadMatchdayCheckinReadiness,
  voluntaryRescheduleDrop,
  emergencyDrop,
  catchUpResetSchedule,
  requestMutualOverridePlayNow,
  pressPlayNowReady,
  resetPlayNowSession,
  pressAlreadyPlayed,
  cancelAlreadyPlayed,
  requestMutualOverrideNewTime,
  confirmMutualOverride,
  cancelMutualOverride,
  formatKickoff,
  formatKickoffPair,
  formatKickoffSlotHtml,
  setSeasonCalendarMonths,
  UK_TZ,
  filterSelectableKickoffSlots,
  isSelectableKickoffSlot,
  formatOwnerNowLine,
  formatResponseDeadlineLine,
  dateFromZonedDateTimeLocal,
  zonedDateTimeLocalValue,
  snapToUkHalfHourSlot,
  snapToUkTenMinSlot,
  priorProposedKickoffSet,
  kickoffIsoKey,
  buildCompromiseMidpointSlots,
} from "./match_scheduling.js?v=20261106-play-now-press";
import { loadSeasonCalendarMonths } from "./competition_calendar.js";
import {
  loadFixtureUnavailable,
  formatFixtureUnavailableBannerHtml,
} from "./player_discipline.js?v=20261028-unavail";
import {
  matchConsoleStripHtml,
  pitchBehaviourPanelHtml,
  wirePitchAck,
} from "./matchday_console_rules.js?v=20261012-console-text2";
import {
  downloadIcs,
  fixtureKickoffEvent,
  fixtureKickoffFilename,
} from "./calendar_ics.js?v=20261020-ics-teams";

function replayResetConfirmMessage(allowances) {
  if (allowances?.can_replay_reset) {
    return "Match was not played? Reset and pick a new kick-off in this fixture's play month. Does not use your reschedule allowance. No-show fines/strikes already applied stay in place.";
  }
  return "Reset this catch-up fixture and pick a new kick-off in the current GPSL month? Does not use your reschedule allowance.";
}

/** After check-in window: choose enter result (if allowed) or reschedule. */
function missChoicePanelHtml(f, ci, al) {
  const mode = String(ci?.miss_choice_mode || "");
  if (ci?.result_pending) {
    return `<div class="panel" style="border-color:#e8a87c;">
      <h2>Result pending</h2>
      <p class="meta">A result is waiting for confirmation. Confirm or reject it in Inbox / Match Day before picking a new time.</p>
      <div class="actions">
        <a href="matchday.html?fixture=${f.id}" class="button" style="text-decoration:none;display:inline-block;">Open Match Day</a>
      </div>
    </div>`;
  }
  if (!mode) return "";

  const canEnter = !!ci.can_enter_result;
  const canReset = !!(al.can_replay_reset || al.can_catch_up_reset);
  const resetLabel = al.can_replay_reset
    ? "Didn't play — pick new time"
    : "Didn't play — reset for catch-up";

  let blurb = "";
  if (mode === "onesided_checked") {
    blurb =
      "Opponent missed check-in — their fine/strike still apply. If you played, enter the result (they confirm + stats). If not, pick a new time.";
  } else if (mode === "onesided_missed") {
    blurb =
      "You missed check-in — your fine/strike still apply. Only your opponent can enter the result if you played. If the match was not played, pick a new time.";
  } else if (mode === "both_miss") {
    blurb =
      "Neither club checked in — fines/strikes still apply to both. If you played, either owner can enter the result (opponent confirms + stats). If not, pick a new time.";
  } else {
    return "";
  }

  return `<div class="panel" style="border-color:var(--gpsl-accent, #ff9900);">
    <h2>Check-in window closed</h2>
    <p class="meta">${blurb}</p>
    <div class="actions">
      ${
        canEnter
          ? `<a href="matchday.html?fixture=${f.id}" class="button" style="text-decoration:none;display:inline-block;">Match was played — enter result</a>`
          : ""
      }
      ${
        canReset
          ? `<button type="button" id="catchUpResetBtn" class="button secondary">${resetLabel}</button>`
          : ""
      }
    </div>
  </div>`;
}

let ctx = null;
/** match_schedule_fixture_deadlines(): propose-by / last play lock */
let deadlines = null;
let fixtureId = null;
let selectedKickoff = null;
let myClub = { short: null };
/** @type {import("./player_discipline.js").FixtureUnavailablePayload|null} */
let fixtureUnavailable = null;

function isSquadCheckinBlockMessage(msg) {
  const text = String(msg || "").toLowerCase();
  return (
    text.includes("matchday squad") ||
    text.includes("saved starting xi") ||
    text.includes("saved matchday xi") ||
    text.includes("injured or suspended players")
  );
}

function matchdayFixHref(fid) {
  return `matchday.html?fixture=${encodeURIComponent(fid)}&fix_checkin_squad=1`;
}

function unavailablePanelHtml(f) {
  return formatFixtureUnavailableBannerHtml(fixtureUnavailable, {
    homeName: fullClubName(f.home_club_short_name) || f.home_club_short_name,
    awayName: fullClubName(f.away_club_short_name) || f.away_club_short_name,
    clubShort: myClub?.short || ctx?.my_club_short_name || null,
  });
}

function setStatus(msg, isError = false) {
  const el = document.getElementById("scheduleStatus");
  if (el) {
    el.textContent = msg || "";
    el.style.color = isError ? "#f88" : "#8c8";
  }
}

function parseFixtureId() {
  const q = new URLSearchParams(window.location.search);
  const raw = q.get("fixture");
  const id = raw ? Number(raw) : NaN;
  return Number.isFinite(id) && id > 0 ? id : null;
}

function fixtureTitle(f) {
  const home = fullClubName(f.home_club_short_name);
  const away = fullClubName(f.away_club_short_name);
  const comp = formatFixtureCompetition(f);
  return comp ? `${comp} · ${home} vs ${away}` : `${home} vs ${away}`;
}

function tzDisplayName(tz) {
  return String(tz || UK_TZ).replace(/_/g, " ");
}

function localNowInTz(tz) {
  return new Date().toLocaleString("en-GB", {
    timeZone: tz || UK_TZ,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/** Home + away timezone strip so owners can verify local matching. */
function timezoneComparePanelHtml(f, homeTz, awayTz, ownerTz) {
  const homeName = fullClubName(f.home_club_short_name) || f.home_club_short_name;
  const awayName = fullClubName(f.away_club_short_name) || f.away_club_short_name;
  const hTz = homeTz || UK_TZ;
  const aTz = awayTz || UK_TZ;
  const same = hTz === aTz;
  return `
    <div class="tz-compare" role="region" aria-label="Club timezones">
      <div class="tz-compare-title">Timezones (for matching)</div>
      <div class="tz-compare-grid">
        <div class="tz-compare-card">
          <div class="tz-compare-club">Home · ${escapeHtmlLite(homeName)}</div>
          <div class="tz-compare-zone">${escapeHtmlLite(tzDisplayName(hTz))}</div>
          <div class="tz-compare-now">Now: ${escapeHtmlLite(localNowInTz(hTz))}</div>
        </div>
        <div class="tz-compare-card">
          <div class="tz-compare-club">Away · ${escapeHtmlLite(awayName)}</div>
          <div class="tz-compare-zone">${escapeHtmlLite(tzDisplayName(aTz))}</div>
          <div class="tz-compare-now">Now: ${escapeHtmlLite(localNowInTz(aTz))}</div>
        </div>
      </div>
      <p class="tz-compare-note">
        ${
          same
            ? "Both clubs use the same timezone — compatible slots use the same local clock."
            : "Slot buttons show each kick-off in your local time, with UK / home / away underneath so you can check the match."
        }
        Your zone: <b>${escapeHtmlLite(tzDisplayName(ownerTz || UK_TZ))}</b>
        (${escapeHtmlLite(localNowInTz(ownerTz || UK_TZ))}).
      </p>
    </div>`;
}

function escapeHtmlLite(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const POKE_NEAR_MS = 2 * 60 * 60 * 1000;

/** Slots within 2h of any slot in the other list (absolute UTC gap). */
function pokeNearIsoSets(oppSlots, ownSlots, withinMs = POKE_NEAR_MS) {
  const oppNear = new Set();
  const ownNear = new Set();
  /** @type {Map<string, number>} iso → closest gap ms */
  const closestGap = new Map();
  const opp = (oppSlots || []).map((iso) => ({ iso, t: new Date(iso).getTime() }))
    .filter((x) => Number.isFinite(x.t));
  const own = (ownSlots || []).map((iso) => ({ iso, t: new Date(iso).getTime() }))
    .filter((x) => Number.isFinite(x.t));

  for (const a of opp) {
    for (const b of own) {
      const gap = Math.abs(a.t - b.t);
      if (gap >= withinMs || gap === 0) continue;
      oppNear.add(a.iso);
      ownNear.add(b.iso);
      const prevA = closestGap.get(a.iso);
      if (prevA == null || gap < prevA) closestGap.set(a.iso, gap);
      const prevB = closestGap.get(b.iso);
      if (prevB == null || gap < prevB) closestGap.set(b.iso, gap);
    }
  }
  return { oppNear, ownNear, closestGap };
}

function formatNearGapLabel(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return "";
  const mins = Math.round(ms / 60000);
  if (mins < 60) return `${mins} min apart`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m ? `${h}h ${m}m apart` : `${h}h apart`;
}

/**
 * Gap 0 → green, gap at 2h → red (HSL). Returns CSS vars for the slot button.
 * @param {number} gapMs
 */
function pokeNearGradeStyle(gapMs) {
  const t = Math.min(1, Math.max(0, Number(gapMs) / POKE_NEAR_MS));
  // 120 = green, 60 = yellow, 0 = red
  const hue = Math.round(120 * (1 - t));
  return {
    borderColor: `hsl(${hue} 58% 42%)`,
    background: `hsl(${hue} 28% 14%)`,
    tagColor: `hsl(${hue} 70% 72%)`,
    mainColor: `hsl(${hue} 55% 82%)`,
  };
}

function appendKickoffSlotButtons(
  container,
  slots,
  {
    homeTz,
    awayTz,
    ownerTz,
    onSelect,
    excludeIso,
    nearIsoSet,
    nearGapByIso,
    usedIsoSet,
    compromiseMetaByIso,
    exactMatchIsoSet,
  }
) {
  if (!container) return 0;

  const selectable = filterSelectableKickoffSlots(slots, ownerTz);
  let count = 0;

  for (const iso of selectable) {
    if (excludeIso && iso === excludeIso) continue;
    const key = kickoffIsoKey(iso);
    const alreadyUsed = usedIsoSet?.has(key);
    const btn = document.createElement("button");
    btn.type = "button";
    const gapMs = nearGapByIso?.get(iso) ?? nearGapByIso?.get(key);
    // Exact mutual match always wins over compromise / near tagging
    const isExact = exactMatchIsoSet?.has(key) || exactMatchIsoSet?.has(iso);
    const compromise =
      !isExact && (compromiseMetaByIso?.get(key) || compromiseMetaByIso?.get(iso));
    const isCompromise = Boolean(compromise);
    const isNear =
      !isExact && !isCompromise && nearIsoSet?.has(iso) && Number.isFinite(gapMs);
    btn.className = [
      "slot-btn",
      isExact ? "slot-exact" : "",
      isCompromise ? "slot-compromise" : "",
      isNear ? "slot-near" : "",
      alreadyUsed ? "slot-used" : "",
    ]
      .filter(Boolean)
      .join(" ");
    btn.dataset.kickoff = iso;
    const gapLabel = isNear || isCompromise
      ? formatNearGapLabel(isCompromise ? compromise.gapMs : gapMs)
      : "";
    if (alreadyUsed) {
      btn.title = "Already suggested in this arrangement — pick a different time";
      btn.disabled = true;
    } else if (isExact) {
      btn.title = "Exact match — both clubs are free at this kick-off";
    } else if (isCompromise) {
      const kind = compromise?.kind === "endpoint" ? "nearby exclusive time" : "midpoint";
      btn.title = gapLabel
        ? `Compromise · ${kind} (${gapLabel} from the other club’s slot)`
        : `Compromise · ${kind}`;
    } else if (gapLabel) {
      btn.title = `Within 2 hours of a slot on the other list (${gapLabel}) — greener = closer`;
    } else {
      btn.title = "";
    }
    if (isNear && !alreadyUsed) {
      const grade = pokeNearGradeStyle(gapMs);
      btn.style.setProperty("--near-border", grade.borderColor);
      btn.style.setProperty("--near-bg", grade.background);
      btn.style.setProperty("--near-tag", grade.tagColor);
      btn.style.setProperty("--near-main", grade.mainColor);
    }
    const tagHtml = alreadyUsed
      ? `<span class="slot-used-tag">Already suggested</span>`
      : isExact
        ? `<span class="slot-exact-tag">Exact match</span>`
        : isCompromise
          ? `<span class="slot-compromise-tag">${
              compromise?.kind === "endpoint" ? "Compromise" : "Compromise · mid"
            }${gapLabel ? ` · ${escapeHtmlLite(gapLabel)}` : ""}</span>`
          : isNear
            ? `<span class="slot-near-tag">Near · ${escapeHtmlLite(gapLabel || "<2h")}</span>`
            : "";
    btn.innerHTML =
      formatKickoffSlotHtml(iso, {
        ownerTz,
        homeTz,
        awayTz,
      }) + tagHtml;
    if (alreadyUsed) {
      btn.style.cursor = "not-allowed";
    } else if (onSelect) {
      btn.onclick = () => onSelect(iso, btn, container);
    } else {
      btn.disabled = true;
      btn.style.cursor = "default";
      if (!isNear && !isCompromise && !isExact) btn.style.opacity = "0.65";
    }
    container.appendChild(btn);
    count += 1;
  }

  return count;
}

function setPokeSelection(iso, { homeTz, awayTz, ownerTz, clearLists = true } = {}) {
  selectedKickoff = iso || null;
  const proposeBtn = document.getElementById("proposeBtn");
  if (proposeBtn) proposeBtn.disabled = !selectedKickoff;
  const preview = document.getElementById("pokePreview");
  const dt = document.getElementById("pokeDateTime");
  if (preview) {
    if (selectedKickoff) {
      preview.hidden = false;
      preview.innerHTML = `Poke will send: <span class="kickoff-line">${formatKickoffPair(
        selectedKickoff,
        homeTz,
        awayTz
      )}</span>`;
    } else {
      preview.hidden = true;
      preview.textContent = "";
    }
  }
  if (dt && selectedKickoff) {
    dt.value = zonedDateTimeLocalValue(selectedKickoff, ownerTz);
  }
  if (clearLists) {
    document
      .querySelectorAll("#oppSlotList .slot-btn, #ownSlotList .slot-btn")
      .forEach((b) => b.classList.remove("selected"));
  }
}

function wirePokePanel({
  homeTz,
  awayTz,
  ownerTz,
  oppTz,
  selectableOppSlots,
  selectableOwnSlots,
  usedIsoSet,
}) {
  const oppList = document.getElementById("oppSlotList");
  const ownList = document.getElementById("ownSlotList");
  const compromiseList = document.getElementById("compromiseSlotList");
  const dt = document.getElementById("pokeDateTime");
  const useBtn = document.getElementById("pokeUseBtn");

  const { oppNear, ownNear, closestGap } = pokeNearIsoSets(
    selectableOppSlots,
    selectableOwnSlots
  );

  const compromises = buildCompromiseMidpointSlots(
    selectableOwnSlots,
    selectableOppSlots,
    { ownerTimezone: ownerTz, excludeIsoSet: usedIsoSet }
  );
  const compromiseIsos = compromises.map((c) => c.iso);
  const compromiseMetaByIso = new Map(
    compromises.map((c) => [kickoffIsoKey(c.iso), c])
  );

  const selectPokeSlot = (iso, btn, list) => {
    if (usedIsoSet?.has(kickoffIsoKey(iso))) return;
    setPokeSelection(iso, { homeTz, awayTz, ownerTz, clearLists: false });
    document
      .querySelectorAll(
        "#oppSlotList .slot-btn, #ownSlotList .slot-btn, #compromiseSlotList .slot-btn"
      )
      .forEach((b) => b.classList.remove("selected"));
    list.querySelectorAll(".slot-btn").forEach((b) => b.classList.remove("selected"));
    btn.classList.add("selected");
  };

  if (oppList) {
    appendKickoffSlotButtons(oppList, selectableOppSlots, {
      homeTz,
      awayTz,
      // Primary = your clock so both lists compare; opp local is on the sub line
      ownerTz,
      nearIsoSet: oppNear,
      nearGapByIso: closestGap,
      usedIsoSet,
      onSelect: (iso, btn, list) => selectPokeSlot(iso, btn, list),
    });
  }

  if (ownList) {
    appendKickoffSlotButtons(ownList, selectableOwnSlots, {
      homeTz,
      awayTz,
      ownerTz,
      nearIsoSet: ownNear,
      nearGapByIso: closestGap,
      usedIsoSet,
      onSelect: null, // comparison only
    });
  }

  if (compromiseList) {
    if (compromiseIsos.length) {
      appendKickoffSlotButtons(compromiseList, compromiseIsos, {
        homeTz,
        awayTz,
        ownerTz,
        usedIsoSet,
        compromiseMetaByIso,
        onSelect: (iso, btn, list) => selectPokeSlot(iso, btn, list),
      });
    } else {
      compromiseList.innerHTML =
        '<p class="meta" style="color:#888;">No compromise between nearby exclusive slots (need two under 2 hours apart).</p>';
    }
  }

  const nearNote = document.getElementById("pokeNearNote");
  if (nearNote) {
    const n = oppNear.size;
    const c = compromises.length;
    nearNote.hidden = n === 0 && c === 0;
    if (n || c) {
      const nearBit =
        n > 0
          ? `${n} opponent time${n === 1 ? "" : "s"} within 2 hours of yours (green = closest, red = nearer 2h)`
          : "";
      const midBit =
        c > 0
          ? `${c} compromise${c === 1 ? "" : "s"} suggested (meet-them / meet-you / mid)`
          : "";
      nearNote.textContent = [nearBit, midBit].filter(Boolean).join(" · ") + ".";
    }
  }

  if (dt && !dt.value) {
    const first =
      selectableOppSlots[0] ||
      selectableOwnSlots[0] ||
      null;
    if (first) {
      dt.value = zonedDateTimeLocalValue(first, ownerTz);
    }
  }

  const applyFreeTime = () => {
    if (!dt?.value) {
      setStatus("Pick a date and time first.", true);
      return;
    }
    const raw = dateFromZonedDateTimeLocal(dt.value, ownerTz);
    if (!raw) {
      setStatus("Could not read that date/time.", true);
      return;
    }
    const snapped = snapToUkHalfHourSlot(raw);
    if (!snapped) {
      setStatus("Could not snap to a UK 30‑minute kick-off.", true);
      return;
    }
    const iso = snapped.toISOString();
    if (!isSelectableKickoffSlot(iso, ownerTz)) {
      setStatus("That kick-off is in the past — pick a future time.", true);
      return;
    }
    if (usedIsoSet?.has(kickoffIsoKey(iso))) {
      setStatus(
        "That kick-off was already suggested in this arrangement — pick a different time.",
        true
      );
      return;
    }
    setPokeSelection(iso, { homeTz, awayTz, ownerTz });
    setStatus("");
  };

  if (useBtn) useBtn.onclick = applyFreeTime;
  if (dt) {
    dt.addEventListener("change", () => {
      if (dt.value) applyFreeTime();
    });
  }
}

/** Pending mutual / Discord-lock confirm panel (works before or after agreed). */
function mutualPendingPanelHtml(mo, homeTz, awayTz) {
  if (!mo) return "";
  const fromName = fullClubName(mo.requested_by_club_short_name);
  const kindLabel =
    mo.kind === "play_now"
      ? "bring kick-off forward"
      : "lock this kick-off";
  const cancelLabel = mo.can_confirm ? "Decline" : "Cancel request";
  const cancelTitle = mo.can_confirm
    ? "Decline this Discord lock — you did not agree this time"
    : "Cancel your Discord lock request";
  return `
    <div class="panel mutual-panel">
      <h2>Mutual confirm pending</h2>
      <p class="status-pending">
        <b>${fromName}</b> wants to ${kindLabel}:
        <span class="kickoff-line">${formatKickoffPair(mo.proposed_kickoff_at, homeTz, awayTz)}</span>
      </p>
      <p class="meta">Both clubs must agree. Deadlines keep running until locked. If you did not agree this time on Discord, use <b>Decline</b>.</p>
      <div class="actions">
        ${mo.can_confirm ? '<button type="button" id="confirmMutualBtn" class="button">Confirm</button>' : ""}
        ${mo.my_confirmed && !mo.can_confirm ? '<span class="meta">You confirmed — waiting for opponent.</span>' : ""}
        ${
          mo.can_cancel
            ? `<button type="button" id="cancelMutualBtn" class="button secondary" title="${cancelTitle}">${cancelLabel}</button>`
            : ""
        }
      </div>
    </div>
  `;
}

function wireMutualPendingButtons() {
  const confirmMutualBtn = document.getElementById("confirmMutualBtn");
  if (confirmMutualBtn) {
    confirmMutualBtn.onclick = async () => {
      confirmMutualBtn.disabled = true;
      setStatus("Confirming…");
      const res = await confirmMutualOverride(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, !res.soft);
        confirmMutualBtn.disabled = false;
        if (res.soft) await reload();
        return;
      }
      setStatus(res.applied ? "Kick-off locked." : res.msg || "Confirmed.");
      await reload();
    };
  }

  const cancelMutualBtn = document.getElementById("cancelMutualBtn");
  if (cancelMutualBtn) {
    cancelMutualBtn.onclick = async () => {
      const declining = /decline/i.test(cancelMutualBtn.textContent || "");
      if (
        !confirm(
          declining
            ? "Decline this Discord lock?\n\nUse this if you did not agree that kick-off on Discord. They can propose a different time on Schedule."
            : "Cancel this mutual request?"
        )
      ) {
        return;
      }
      cancelMutualBtn.disabled = true;
      const res = await cancelMutualOverride(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, !res.soft);
        cancelMutualBtn.disabled = false;
        return;
      }
      setStatus(res.msg || (declining ? "Declined." : "Request cancelled."));
      await reload();
    };
  }
}

/** Discord → site lock body (embedded in Agreed on Discord tab). */
function discordLockPanelBodyHtml() {
  return `
    <div id="discordLockPanel">
      <h2>Agreed on Discord scheduling</h2>
      <p class="meta">Use this only when you already agreed a time on Discord. Pick that time, then send it for your opponent to confirm on the site. Reply and arrangement clocks keep running until both lock.</p>
      <div class="slot-list" id="discordLockSlotList"></div>
      <div class="actions">
        <button type="button" id="discordLockBtn" class="button" disabled>Lock this kick-off (both confirm)</button>
      </div>
    </div>
  `;
}

function wireScheduleModeTabs(defaultTab = "gpsl") {
  const tabs = Array.from(document.querySelectorAll(".schedule-tab"));
  const panes = {
    gpsl: document.getElementById("tabGpsl"),
    discord: document.getElementById("tabDiscord"),
  };
  if (!tabs.length || !panes.gpsl || !panes.discord) return;

  const activate = (key) => {
    tabs.forEach((tab) => {
      const on = tab.dataset.tab === key;
      tab.classList.toggle("active", on);
      tab.setAttribute("aria-selected", on ? "true" : "false");
    });
    Object.entries(panes).forEach(([k, pane]) => {
      if (!pane) return;
      pane.hidden = k !== key;
    });
  };

  tabs.forEach((tab) => {
    tab.onclick = () => activate(tab.dataset.tab || "gpsl");
  });
  activate(defaultTab === "discord" ? "discord" : "gpsl");
}

function wireDiscordLockPanel(slots, homeTz, awayTz, ownerTz, usedIsoSet = null) {
  let discordSelected = null;
  const list = document.getElementById("discordLockSlotList");
  const btn = document.getElementById("discordLockBtn");
  if (!list || !btn) return;

  const count = appendKickoffSlotButtons(list, slots || [], {
    homeTz,
    awayTz,
    ownerTz,
    usedIsoSet,
    onSelect: (iso, el, container) => {
      if (usedIsoSet?.has(kickoffIsoKey(iso))) return;
      discordSelected = iso;
      container.querySelectorAll(".slot-btn").forEach((b) => b.classList.remove("selected"));
      el.classList.add("selected");
      btn.disabled = false;
    },
  });
  if (!count) {
    list.innerHTML =
      '<p class="meta" style="color:#888;">No future slots available — set weekly availability on Owner Details, or free a booked time.</p>';
  }

  btn.onclick = async () => {
    if (!discordSelected) return;
    if (
      !confirm(
        "Lock this Discord-agreed kick-off? Your opponent must confirm. Reply deadlines keep running until both lock."
      )
    ) {
      return;
    }
    btn.disabled = true;
    setStatus("Sending Discord lock request…");
    const res = await requestMutualOverrideNewTime(fixtureId, discordSelected);
    if (!res.ok) {
      setStatus(res.msg, true);
      btn.disabled = false;
      return;
    }
    setStatus("Request sent — waiting for opponent to confirm.");
    await reload();
  };
}

function formatUkWhen(iso) {
  if (!iso) return "";
  const label = formatKickoff(iso, UK_TZ);
  return label && label !== "—" ? `${label} UK` : "";
}

function relWhen(iso) {
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "";
  const diff = t - Date.now();
  const mins = Math.round(Math.abs(diff) / 60000);
  const txt =
    mins < 60 ? `${mins}m` : mins < 2880 ? `${Math.floor(mins / 60)}h` : `${Math.floor(mins / 1440)}d ${Math.floor((mins % 1440) / 60)}h`;
  return diff >= 0 ? `in ${txt}` : `${txt} ago`;
}

/** Propose-by deadline + last play date for an unagreed fixture. */
function deadlineBoxHtml(f) {
  const d = deadlines;
  if (!d?.ok || ctx?.is_catch_up) return finalPlayLineHtml();
  const now = Date.now();
  const proposeBy = d.propose_by ? new Date(d.propose_by).getTime() : NaN;
  const lateFrom = d.late_fee_from ? new Date(d.late_fee_from).getTime() : NaN;
  const homeName = fullClubName(f.home_club_short_name) || f.home_club_short_name;
  let html = "";

  if (Number.isFinite(proposeBy) && proposeBy > now && !d.home_has_proposed) {
    const late = Number.isFinite(lateFrom) && now >= lateFrom;
    if (ctx.my_role === "home") {
      html = `<div class="deadline-box${late ? " deadline-late" : ""}">
        <b>Propose a kick-off by ${formatUkWhen(d.propose_by)}</b> (${relWhen(d.propose_by)}).
        ${
          late
            ? "The ₿1m late fee now applies — propose now to avoid the ₿2.5m no-proposal fine."
            : `Proposing after ${formatUkWhen(d.late_fee_from)} costs a ₿1m late fee; no proposal by the deadline is a ₿2.5m fine.`
        }
      </div>`;
    } else {
      html = `<div class="deadline-box deadline-info">
        <b>${homeName}</b> (home) must propose a kick-off by ${formatUkWhen(d.propose_by)}.
        You don't need to do anything yet — you'll get an <a href="inbox.html">Inbox</a> message to accept or counter.
      </div>`;
    }
  }
  return html + finalPlayLineHtml();
}

async function fillDiscordOpponentTag(f) {
  const el = document.getElementById("discordOpponentTag");
  if (!el || el.dataset.loaded === "1") return;
  el.dataset.loaded = "1";
  const opp = ctx?.my_role === "home" ? f.away_club_short_name : f.home_club_short_name;
  const { data } = await supabase.from("Clubs").select("owner").eq("ShortName", opp).maybeSingle();
  const tag = String(data?.owner || "").trim();
  if (tag) el.innerHTML = ` with <b>${tag.replace(/[<>&"]/g, "")}</b>`;
}

function finalPlayLineHtml() {
  const d = deadlines;
  if (!d?.ok || !d.final_play_lock) return "";
  return `<p class="meta">Last chance to play: before <b>${formatUkWhen(d.final_play_lock)}</b>.
    If it's still unplayed then, the result is awarded on scheduling activity (a true tie is recorded 0–0).</p>`;
}

function catchUpBannerHtml() {
  if (!ctx?.is_catch_up) return "";
  const playMonth = GPSL_MONTH_LABELS[ctx.fixture?.gpsl_month] || ctx.fixture?.gpsl_month || "original";
  const prop = ctx.proposal_window || {};
  const schedMonth =
    prop.gpsl_month && GPSL_MONTH_LABELS[prop.gpsl_month]
      ? GPSL_MONTH_LABELS[prop.gpsl_month]
      : prop.gpsl_month
        ? prop.gpsl_month
        : "the current GPSL month";
  return `<div class="catch-up-banner">
    <strong>Catch-up match</strong> — originally due in <b>${playMonth}</b>.
    Arrange and play through <b>${schedMonth}</b> until completed.
  </div>`;
}

function holidayCorridorEndLabel() {
  const prop = ctx?.proposal_window || {};
  const endKey = String(prop.gpsl_month || ctx?.fixture?.gpsl_month || "").toLowerCase();
  return GPSL_MONTH_LABELS[endKey] || prop.gpsl_month || null;
}

function holidayEarlyBannerHtml() {
  if (!ctx?.is_holiday_early) return "";
  const playMonthKey = String(ctx.fixture?.gpsl_month || "").toLowerCase();
  const playMonth =
    GPSL_MONTH_LABELS[playMonthKey] || ctx.fixture?.gpsl_month || "later";
  const endLabel = holidayCorridorEndLabel() || playMonth;
  const windowBit =
    endLabel && String(endLabel).toLowerCase() !== String(playMonth).toLowerCase()
      ? `from now through <b>${endLabel}</b> (holiday corridor — early arrange plus catch-up)`
      : `during <b>${playMonth}</b>`;
  return `<div class="catch-up-banner holiday-early-banner">
    <strong>Holiday early play</strong> — this <b>${playMonth}</b> fixture is unlocked now.
    Arrange and play ${windowBit}. Both clubs need a full squad (min 24).
    To play before a later agreed kick-off (e.g. before 19:00): open this Schedule page and use <b>Play now</b> (both must confirm) — Match Day alone has no Play now button.
  </div>`;
}

function noShowLadderBannerHtml(f) {
  const ladder = ctx?.no_show_ladder || {};
  const sch = ctx?.schedule || {};
  const attempt = Number(ladder.play_attempt_count ?? sch.play_attempt_count ?? 0);
  const attempt3 = !!(ladder.attempt3_active || ladder.open_play_active || sch.open_play_active || attempt >= 3);
  const deadlineKey = String(
    ladder.open_play_deadline_gpsl_month || sch.open_play_deadline_gpsl_month || ""
  ).toLowerCase();
  const deadlineLabel = deadlineKey
    ? GPSL_MONTH_LABELS[deadlineKey] || deadlineKey
    : null;
  const homeN = Number(ladder.home_no_show_count ?? 0);
  const awayN = Number(ladder.away_no_show_count ?? 0);
  const homeStrikes = Number(ladder.home_season_strikes ?? 0);
  const awayStrikes = Number(ladder.away_season_strikes ?? 0);
  const homeName = fullClubName(f.home_club_short_name);
  const awayName = fullClubName(f.away_club_short_name);

  if (attempt < 1 && !attempt3) return "";

  const counts = `Fixture no-shows: ${homeName} <b>${homeN}</b>/3 · ${awayName} <b>${awayN}</b>/3. Season strikes: ${homeName} <b>${homeStrikes}</b> · ${awayName} <b>${awayStrikes}</b>.`;
  const fines =
    "One-sided miss → ₿500k / ₿1m / ₿1.5m by fixture count (+ season strike). 3rd on this fixture → 0–3. Both miss → each ₿500k + 1 strike. Every 3rd season strike → ₿2.5m.";

  if (attempt3) {
    return `<div class="catch-up-banner">
      <strong>Attempt 3</strong> — rearrange freely through
      <b>${deadlineLabel || "original month + 2 GPSL months"}</b> (Play now OK).
      ${counts} ${fines}
      Still unplayed at that lock → awarded to fewer no-shows (activity if tied).
    </div>`;
  }

  return `<div class="catch-up-banner">
    <strong>Attempt ${attempt || 1}</strong> — ${counts} ${fines}
  </div>`;
}

function alreadyPlayedPanelHtml() {
  const ap = ctx?.already_played;
  if (!ap || ap.completed) return "";
  if (ap.available === false && !ap.can_press && !ap.my_pressed) return "";
  if (ctx?.my_has_manager === false) return "";

  const bothPending =
    ap.status === "open" && (ap.home_pressed || ap.away_pressed) && !(ap.home_pressed && ap.away_pressed);

  let actions = "";
  if (ap.can_press) {
    actions = `<button type="button" id="alreadyPlayedBtn" class="button secondary">Already played</button>`;
  } else if (ap.can_cancel) {
    actions = `<button type="button" id="alreadyPlayedCancelBtn" class="button secondary">Cancel my confirm</button>`;
  }

  const statusLine = bothPending
    ? ap.my_pressed
      ? `<p class="meta" style="color:#e8a87c;"><b>Waiting for opponent</b> to confirm Already played.</p>`
      : `<p class="meta" style="color:#e8a87c;"><b>Opponent confirmed</b> — confirm if you already played too.</p>`
    : "";

  return `
    <div class="panel" style="border-color:#6a3a28;background:#1a100c;">
      <h2>Already played?</h2>
      <p class="meta">
        You played this fixture without finishing GPSL arrangement.
        <b>Both clubs must confirm.</b> Then each club pays <b>₿500k</b> and takes
        <b>1 season no-show strike</b> (counts toward every 3rd → ₿2.5m), and Match Day unlocks for enter result / confirm + stats.
      </p>
      ${statusLine}
      ${actions ? `<div class="actions">${actions}</div>` : ""}
    </div>`;
}

function wireAlreadyPlayedButtons() {
  const pressBtn = document.getElementById("alreadyPlayedBtn");
  if (pressBtn) {
    pressBtn.onclick = async () => {
      if (
        !confirm(
          "Confirm Already played?\n\nWhen both clubs confirm:\n• ₿500k fine each\n• 1 season no-show strike each\n• Match Day unlocks to enter / confirm the result\n\nContinue?"
        )
      ) {
        return;
      }
      pressBtn.disabled = true;
      const res = await pressAlreadyPlayed(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        pressBtn.disabled = false;
        return;
      }
      if (res.data?.completed) {
        setStatus(
          "Both confirmed — ₿500k + strike applied. Enter the result on Match Day."
        );
      } else {
        setStatus("Confirmed — waiting for opponent (₿500k + strike apply when both confirm).");
      }
      await reload();
    };
  }
  const cancelBtn = document.getElementById("alreadyPlayedCancelBtn");
  if (cancelBtn) {
    cancelBtn.onclick = async () => {
      cancelBtn.disabled = true;
      const res = await cancelAlreadyPlayed(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        cancelBtn.disabled = false;
        return;
      }
      setStatus("Already played confirm cancelled.");
      await reload();
    };
  }
}

function renderAgreedPanel(root, f, sch) {
  const homeTz = ctx.home_timezone || UK_TZ;
  const awayTz = ctx.away_timezone || UK_TZ;
  const ownerTz = ctx.my_timezone || UK_TZ;
  const ci = ctx.checkin || {};
  const al = ctx.allowances || {};
  const mo = ctx.mutual_override;
  const moOpts = ctx.mutual_override_options || {};
  const homeName = fullClubName(f.home_club_short_name);
  const awayName = fullClubName(f.away_club_short_name);

  const checkinStatus = `Home (${homeName}): ${ci.home_checked_in ? "checked in ✓" : "waiting…"} · Away (${awayName}): ${ci.away_checked_in ? "checked in ✓" : "waiting…"}`;

  let mutualHtml = "";
  const agreedFuture =
    sch.status === "agreed" &&
    sch.agreed_kickoff_at &&
    new Date(sch.agreed_kickoff_at).getTime() > Date.now();
  const playNowBlockedReason = String(moOpts.play_now_block_reason || "").trim();
  const pn = ctx.play_now_session || {};
  const pnActive = pn.active === true;

  if (mo) {
    mutualHtml = mutualPendingPanelHtml(mo, homeTz, awayTz);
  } else if (agreedFuture && ctx.my_has_manager !== false) {
    const canBringForward = moOpts.can_request_play_now === true;
    const freeNewTimeNote = sch.mutual_override_used
      ? "Free mutual new-time already used for this fixture — Bring KO forward is still available if both agree."
      : "One free mutual new-time per fixture; Bring KO forward can be used again later if both agree.";
    const playNowDefaultRaw = moOpts.play_now_kickoff_at
      ? new Date(moOpts.play_now_kickoff_at)
      : new Date(Date.now() + 5 * 60 * 1000);
    let playNowDefaultDate = snapToUkTenMinSlot(playNowDefaultRaw) || playNowDefaultRaw;
    while (
      playNowDefaultDate &&
      !Number.isNaN(playNowDefaultDate.getTime()) &&
      playNowDefaultDate.getTime() <= Date.now()
    ) {
      playNowDefaultDate = new Date(playNowDefaultDate.getTime() + 10 * 60 * 1000);
    }
    const playNowDefault =
      playNowDefaultDate && !Number.isNaN(playNowDefaultDate.getTime())
        ? zonedDateTimeLocalValue(playNowDefaultDate, ownerTz)
        : "";
    const blockNote =
      !canBringForward && playNowBlockedReason
        ? `<p class="meta" style="color:#fc6;margin-top:8px;"><b>Bring KO forward unavailable:</b> ${escapeHtmlLite(playNowBlockedReason)}</p>`
        : !canBringForward
          ? `<p class="meta" style="color:#fc6;margin-top:8px;"><b>Bring KO forward unavailable</b> right now (holiday early squad, double-booked, or outside the play window).</p>`
          : "";

    const pnSecs = Number(pn.seconds_remaining ?? 0);
    const pnMins = Math.floor(pnSecs / 60);
    const pnRem = pnSecs % 60;
    const pnCountdown = pnActive
      ? `${pnMins}:${String(pnRem).padStart(2, "0")}`
      : "";
    const readyLine = pnActive
      ? `Home: ${pn.home_pressed ? "ready ✓" : "waiting…"} · Away: ${pn.away_pressed ? "ready ✓" : "waiting…"} · Check-ins: Home ${pn.home_checked_in ? "✓" : "—"} · Away ${pn.away_checked_in ? "✓" : "—"}`
      : "";

    let playNowReadyHtml = "";
    if (pnActive && pn.status === "miss_open") {
      const canEnter = pn.can_enter_result === true;
      const canReset = pn.can_reset === true;
      let blurb = "Play now window closed. Fines/strikes already applied. Agreed kick-off stays suspended until you enter a result or reset.";
      if (pn.miss_choice_mode === "onesided_checked") {
        blurb =
          "Opponent missed Play now check-in — their fine/strike still apply. Enter the result if you played, or reset Play now.";
      } else if (pn.miss_choice_mode === "onesided_missed") {
        blurb =
          "You missed Play now check-in — your fine/strike still apply. Only your opponent can enter the result. You may still reset Play now.";
      } else if (pn.miss_choice_mode === "both_miss") {
        blurb =
          "Neither checked in during Play now — fines/strikes still apply. Either owner can enter a result or reset.";
      }
      playNowReadyHtml = `
        <div class="panel mutual-panel" style="border-color:var(--gpsl-accent, #ff9900);">
          <h2>Play now — window closed</h2>
          <p class="meta">${blurb}</p>
          <p class="meta">${readyLine}</p>
          <div class="actions">
            ${
              canEnter
                ? `<a href="matchday.html?fixture=${f.id}" class="button" style="text-decoration:none;display:inline-block;">Match was played — enter result</a>`
                : ""
            }
            ${
              canReset
                ? '<button type="button" id="playNowResetBtn" class="button secondary">Reset Play now (keep agreed KO)</button>'
                : ""
            }
          </div>
        </div>`;
    } else if (pnActive) {
      playNowReadyHtml = `
        <div class="panel mutual-panel" style="border-color:var(--gpsl-accent, #ff9900);">
          <h2>Play now</h2>
          <p class="meta">
            Both owners press <b>Play now</b>, then check in. Shared window:
            <b><span id="playNowCountdown">${pnCountdown}</span></b> left
            (20 min from first press). Agreed KO stays until the match is confirmed played.
            ${pn.ko_forfeit_suspended ? " Original KO check-in fines are <b>suspended</b> while this session is active." : ""}
          </p>
          <p class="meta">${readyLine}</p>
          <div class="actions">
            ${
              pn.can_press
                ? '<button type="button" id="playNowReadyBtn" class="button">Play now</button>'
                : pn.my_pressed
                  ? '<span class="meta">You pressed Play now — waiting for opponent / check-in.</span>'
                  : ""
            }
            ${
              pn.can_check_in
                ? '<button type="button" id="playNowCheckInBtn" class="button">Check in now</button>'
                : ""
            }
            ${
              pn.home_checked_in && pn.away_checked_in
                ? `<a href="matchday.html?fixture=${f.id}" class="button" style="text-decoration:none;display:inline-block;">Enter result on Match Day</a>`
                : ""
            }
            ${
              pn.can_reset
                ? '<button type="button" id="playNowResetBtn" class="button secondary">Cancel Play now</button>'
                : ""
            }
          </div>
        </div>`;
    } else if (pn.can_press === true) {
      playNowReadyHtml = `
        <div class="panel mutual-panel" style="border-color:var(--gpsl-accent, #ff9900);">
          <h2>Play now</h2>
          <p class="meta">
            Ready to play <b>now</b>? First press starts a shared <b>20‑minute</b> check-in window.
            Both must press Play now, then check in. No allowance used. Agreed kick-off stays unless the match is confirmed played.
          </p>
          <div class="actions">
            <button type="button" id="playNowReadyBtn" class="button">Play now</button>
          </div>
        </div>`;
    }

    mutualHtml = `
      ${playNowReadyHtml}
      <div class="panel mutual-panel">
        <h2>Bring KO forward (no allowance used)</h2>
        <p class="meta">
          Keep arranging for later, but move the agreed kick-off to an <b>earlier</b> UK <b>10‑minute</b> time.
          Opponent confirms; then normal check-in ±10 min at the new KO.
        </p>
        ${blockNote}
        <div class="poke-free-row" style="margin-top:10px;">
          <input type="datetime-local" id="playNowDateTime" step="600" value="${playNowDefault}" ${canBringForward && !pnActive ? "" : "disabled"} />
          <button type="button" id="playNowMutualBtn" class="button secondary" ${canBringForward && !pnActive ? "" : "disabled"} title="${
            pnActive
              ? "Finish or cancel Play now first"
              : canBringForward
                ? ""
                : escapeHtmlLite(playNowBlockedReason || "Unavailable")
          }">Request Bring KO forward</button>
        </div>
        <p class="meta" id="playNowPreview" hidden></p>
        <p class="meta" style="margin-top:8px;">${freeNewTimeNote}</p>
        ${
          moOpts.can_request_new_time && !pnActive
            ? `<p class="meta" style="margin-top:12px;">Or change kick-off to another <b>mutual</b> weekly slot:</p>
               <div class="slot-list" id="mutualSlotList"></div>
               <div class="actions">
                 <button type="button" id="newTimeMutualBtn" class="button secondary" disabled>Change kick-off (both agree)</button>
               </div>`
            : ""
        }
      </div>
    `;
  } else if (sch.mutual_override_used) {
    mutualHtml = `<p class="meta">Free mutual new-time already used for this fixture. Bring KO forward appears again while the agreed kick-off is still in the future.</p>`;
  }

  const agreedMeta = document.getElementById("scheduleMeta");
  if (agreedMeta) {
    agreedMeta.textContent = [
      formatFixtureCompetition(f),
      GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month,
      `Home ${tzDisplayName(homeTz)} · Away ${tzDisplayName(awayTz)}`,
      formatOwnerNowLine(ownerTz),
    ]
      .filter(Boolean)
      .join(" · ");
  }

  const ladderActive =
    !!(ctx?.no_show_ladder?.ladder_active || ctx?.no_show_ladder?.open_play_active) ||
    Number(sch.play_attempt_count || 0) >= 3;

  root.innerHTML = `
    ${catchUpBannerHtml()}
    ${holidayEarlyBannerHtml()}
    ${noShowLadderBannerHtml(f)}
    <div class="panel">
      <div class="fixture-head">${fixtureTitle(f)}</div>
      ${timezoneComparePanelHtml(f, homeTz, awayTz, ownerTz)}
      <p class="status-agreed"><b>Kick-off agreed:</b> <span class="kickoff-line">${formatKickoffPair(sch.agreed_kickoff_at, homeTz, awayTz)}</span></p>
      <p class="meta" style="margin-top:6px;">
        <button type="button" id="addKickoffCalendarBtn" class="button secondary">Add to calendar</button>
      </p>
      ${unavailablePanelHtml(f)}
      <p class="meta">${checkinStatus}</p>
      <p class="meta">Check-in opens <b>10 minutes before</b> kick-off and stays open until <b>10 minutes after</b>. Both must check in before Match Day unlocks for the 30-minute block.</p>
      <p class="meta"><b>Your saved Match Day squad is checked when you check in</b> — exactly 11 starters, 12 subs, a goalkeeper, and no injured or suspended players. <a href="${matchdayFixHref(f.id)}" style="color:var(--gpsl-accent, #ff9900);">Check your squad</a> before kick-off.</p>
      <p class="meta">${
        ladderActive
          ? "No-show fines apply instantly when the check-in window closes (see banner). After a miss you can still enter a result if you played, or pick a new time. Month-lock no-show 3–0 is not used on GPSL-arranged fixtures."
          : "If only one club checks in after the window, that is a no-show: instant fine + season strike. Both miss = ₿500k + strike each. Either way you can enter a result if you played, or pick a new time."
      }</p>
      ${
        ci.my_has_manager === false
          ? `<p class="meta" style="color:#f88;"><b>No manager signed</b> — you cannot check in or play until you hire one from the <a href="manager_listings.html" style="color:var(--gpsl-accent, #ff9900);">Manager Transfer Market</a>.</p>`
          : ci.home_has_manager === false || ci.away_has_manager === false
            ? `<p class="meta" style="color:#e8a87c;"><b>Manager required</b> — ${
                ci.home_has_manager === false && ci.away_has_manager === false
                  ? "both clubs"
                  : ci.home_has_manager === false
                    ? "the home club"
                    : "the away club"
              } must have a signed manager before Match Day unlocks.</p>`
            : ""
      }
      <p class="meta" id="checkInSquadGate" style="display:none;color:#f88;"></p>
      <p class="meta">Emergency drops remaining this season: <b>${al.emergency_drops_remaining ?? "—"}</b>/2 · Reschedule this GPSL month: <b>${al.reschedule_used_this_month ? "used" : "available"}</b></p>
      <div id="scheduleConsoleMount">
        ${matchConsoleStripHtml({ isCup: String(f.competition_type || "").toLowerCase() === "cup" })}
        ${pitchBehaviourPanelHtml({ fixtureId: f.id, requireAck: true })}
      </div>
      ${missChoicePanelHtml(f, ci, al)}
      <div class="actions">
        ${ci.can_check_in ? '<button type="button" id="checkInBtn" class="button">Check in now</button>' : ""}
        ${
          !ci.miss_choice_mode && !ci.result_pending && ci.can_play
            ? `<a href="matchday.html?fixture=${f.id}" class="button" style="text-decoration:none;display:inline-block;">Enter result on Match Day</a>`
            : ""
        }
        ${
          !ci.miss_choice_mode && !ci.result_pending && al.can_replay_reset
            ? '<button type="button" id="catchUpResetBtn" class="button secondary">Pick new time to play this month</button>'
            : ""
        }
        ${
          !ci.miss_choice_mode &&
          !ci.result_pending &&
          al.can_catch_up_reset &&
          !al.can_replay_reset
            ? '<button type="button" id="catchUpResetBtn" class="button secondary">Reset for catch-up (pick new time)</button>'
            : ""
        }
        ${al.can_voluntary_drop ? '<button type="button" id="voluntaryDropBtn" class="button secondary">Drop & reschedule (24h+ notice)</button>' : ""}
        ${al.can_emergency_drop && Number(al.emergency_drops_remaining ?? 1) > 0 ? '<button type="button" id="emergencyDropBtn" class="button secondary">Emergency drop (&lt;24h)</button>' : ""}
      </div>
      ${
        al.can_emergency_drop && Number(al.emergency_drops_remaining ?? 1) <= 0
          ? '<p class="meta" style="color:#e8a87c;">No emergency drops left this season — under 24h the kick-off can only change if both clubs agree (below).</p>'
          : ""
      }
      ${finalPlayLineHtml()}
    </div>
    ${mutualHtml}
  `;

  const checkInBtn = document.getElementById("checkInBtn");
  const scheduleConsoleMount = document.getElementById("scheduleConsoleMount");
  if (scheduleConsoleMount) wirePitchAck(scheduleConsoleMount);
  const calBtn = document.getElementById("addKickoffCalendarBtn");
  if (calBtn && sch.agreed_kickoff_at) {
    calBtn.onclick = () => {
      const home = fullClubName(f.home_club_short_name) || f.home_club_short_name;
      const away = fullClubName(f.away_club_short_name) || f.away_club_short_name;
      const calMeta = {
        home,
        away,
        competitionLabel: formatFixtureCompetition(f),
        matchday: f.matchday,
        competition_type: f.competition_type,
      };
      const ev = fixtureKickoffEvent({
        id: f.id,
        kickoffAt: sch.agreed_kickoff_at,
        ...calMeta,
      });
      if (!downloadIcs(fixtureKickoffFilename(calMeta), [ev])) {
        setStatus("Could not build calendar file.", true);
      }
    };
  }
  if (checkInBtn) {
    checkInBtn.onclick = async () => {
      checkInBtn.disabled = true;
      setStatus("Checking in…");
      const res = await checkInToFixture(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        if (isSquadCheckinBlockMessage(res.msg)) {
          window.location = matchdayFixHref(fixtureId);
          return;
        }
        checkInBtn.disabled = false;
        return;
      }
      setStatus("Checked in.");
      await reload();
    };
  }

  applyCheckinSquadGate(f.id);

  const volBtn = document.getElementById("voluntaryDropBtn");
  if (volBtn) {
    volBtn.onclick = async () => {
      if (!confirm("Drop the agreed time and return to scheduling? Uses your 1 reschedule for this GPSL month.")) return;
      volBtn.disabled = true;
      const res = await voluntaryRescheduleDrop(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        volBtn.disabled = false;
        return;
      }
      setStatus("Returned to scheduling — propose a new time.");
      await reload();
    };
  }

  const catchUpResetBtn = document.getElementById("catchUpResetBtn");
  if (catchUpResetBtn) {
    catchUpResetBtn.onclick = async () => {
      if (!confirm(replayResetConfirmMessage(al))) return;
      catchUpResetBtn.disabled = true;
      const res = await catchUpResetSchedule(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        catchUpResetBtn.disabled = false;
        return;
      }
      setStatus("Catch-up reset — propose a new time in the current GPSL month.");
      await reload();
    };
  }

  const emBtn = document.getElementById("emergencyDropBtn");
  if (emBtn) {
    emBtn.onclick = async () => {
      const left = al.emergency_drops_remaining ?? 0;
      if (
        !confirm(
          `Emergency drop (<24h before kick-off)? Uses 1 of ${left} remaining this season and moves the fixture to the next play attempt (1→2→3).`
        )
      ) {
        return;
      }
      emBtn.disabled = true;
      const res = await emergencyDrop(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        emBtn.disabled = false;
        return;
      }
      setStatus("Emergency drop recorded — next attempt; reschedule on this page.");
      await reload();
    };
  }

  let mutualSelectedKickoff = null;
  const mutualSlotList = document.getElementById("mutualSlotList");
  if (mutualSlotList && moOpts.can_request_new_time) {
    const mutualCount = appendKickoffSlotButtons(
      mutualSlotList,
      ctx.intersection_slots || [],
      {
        homeTz,
        awayTz,
        ownerTz,
        excludeIso: sch.agreed_kickoff_at,
        onSelect: (iso, btn, list) => {
          mutualSelectedKickoff = iso;
          list.querySelectorAll(".slot-btn").forEach((b) => b.classList.remove("selected"));
          btn.classList.add("selected");
          const newTimeBtn = document.getElementById("newTimeMutualBtn");
          if (newTimeBtn) newTimeBtn.disabled = false;
        },
      }
    );
    if (!mutualCount) {
      mutualSlotList.innerHTML =
        '<p class="meta" style="color:#888;">No future mutual slots — past times are hidden.</p>';
    }
  }

  const playNowDt = document.getElementById("playNowDateTime");
  const playNowPreview = document.getElementById("playNowPreview");
  const playNowBtn = document.getElementById("playNowMutualBtn");

  const bumpPlayNowToFuture = (snapped) => {
    if (!snapped || Number.isNaN(snapped.getTime())) return null;
    let out = snapped;
    let bumped = false;
    // Local datetime → UK floor snap can land in the past.
    for (let i = 0; i < 144 && out.getTime() <= Date.now(); i++) {
      out = new Date(out.getTime() + 10 * 60 * 1000);
      bumped = true;
    }
    return { iso: out.toISOString(), bumped };
  };

  const readPlayNowIso = () => {
    if (!playNowDt?.value) return null;
    const raw = dateFromZonedDateTimeLocal(playNowDt.value, ownerTz);
    if (!raw) return null;
    const snapped = snapToUkTenMinSlot(raw);
    const bumped = bumpPlayNowToFuture(snapped);
    return bumped?.iso || null;
  };

  const refreshPlayNowPreview = () => {
    if (!playNowPreview) return;
    if (!playNowDt?.value) {
      playNowPreview.hidden = true;
      playNowPreview.textContent = "";
      return;
    }
    const raw = dateFromZonedDateTimeLocal(playNowDt.value, ownerTz);
    const snapped = raw ? snapToUkTenMinSlot(raw) : null;
    const bumped = bumpPlayNowToFuture(snapped);
    if (!bumped?.iso) {
      playNowPreview.hidden = true;
      playNowPreview.textContent = "";
      return;
    }
    playNowPreview.hidden = false;
    playNowPreview.textContent = bumped.bumped
      ? `Will request: ${formatKickoffPair(bumped.iso, homeTz, awayTz)} (bumped to next future UK 10‑min slot)`
      : `Will request: ${formatKickoffPair(bumped.iso, homeTz, awayTz)} (UK 10‑min snap)`;
  };

  if (playNowDt) {
    playNowDt.addEventListener("input", refreshPlayNowPreview);
    playNowDt.addEventListener("change", refreshPlayNowPreview);
    refreshPlayNowPreview();
  }

  const playNowReadyBtn = document.getElementById("playNowReadyBtn");
  if (playNowReadyBtn) {
    playNowReadyBtn.onclick = async () => {
      if (
        !confirm(
          "Press Play now? First press starts a shared 20-minute check-in window. Both owners must press Play now, then check in. No allowance used."
        )
      ) {
        return;
      }
      playNowReadyBtn.disabled = true;
      setStatus("Starting Play now…");
      try {
        const res = await pressPlayNowReady(fixtureId);
        if (!res.ok) {
          const msg = res.msg || "Could not start Play now";
          setStatus(msg, true);
          window.alert(msg);
          playNowReadyBtn.disabled = false;
          return;
        }
        setStatus(
          res.data?.both_ready
            ? "Both ready — check in before the countdown ends."
            : "Play now pressed — waiting for opponent."
        );
        await reload();
      } catch (err) {
        const msg = err?.message || String(err) || "Play now failed";
        setStatus(msg, true);
        window.alert(msg);
        playNowReadyBtn.disabled = false;
      }
    };
  }

  const playNowCheckInBtn = document.getElementById("playNowCheckInBtn");
  if (playNowCheckInBtn) {
    playNowCheckInBtn.onclick = async () => {
      playNowCheckInBtn.disabled = true;
      setStatus("Checking in…");
      const res = await checkInToFixture(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        playNowCheckInBtn.disabled = false;
        return;
      }
      setStatus("Checked in.");
      await reload();
    };
  }

  const playNowResetBtn = document.getElementById("playNowResetBtn");
  if (playNowResetBtn) {
    playNowResetBtn.onclick = async () => {
      if (
        !confirm(
          "Reset Play now? Agreed kick-off stays. Any Play now fines/strikes already applied stay. Check-ins from this session are cleared."
        )
      ) {
        return;
      }
      playNowResetBtn.disabled = true;
      const res = await resetPlayNowSession(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        playNowResetBtn.disabled = false;
        return;
      }
      setStatus(res.data?.message || "Play now cleared.");
      await reload();
    };
  }

  const pnCountdownEl = document.getElementById("playNowCountdown");
  if (pnCountdownEl && pn?.window_ends_at) {
    const endsAt = new Date(pn.window_ends_at).getTime();
    const tick = () => {
      const left = Math.max(0, Math.floor((endsAt - Date.now()) / 1000));
      const m = Math.floor(left / 60);
      const s = left % 60;
      pnCountdownEl.textContent = `${m}:${String(s).padStart(2, "0")}`;
      if (left <= 0) {
        clearInterval(pnTimer);
        void reload();
      }
    };
    const pnTimer = setInterval(tick, 1000);
    tick();
  }

  if (playNowBtn && !playNowBtn.disabled) {
    playNowBtn.onclick = async () => {
      if (moOpts.can_request_play_now !== true) {
        setStatus(
          playNowBlockedReason ||
            "Bring KO forward is unavailable for this fixture right now.",
          true
        );
        return;
      }
      const iso = readPlayNowIso();
      if (!iso) {
        setStatus("Pick a Bring KO forward date/time first.", true);
        return;
      }
      if (new Date(iso).getTime() <= Date.now()) {
        setStatus("That kick-off is already in the past — pick a later time.", true);
        return;
      }
      if (new Date(iso).getTime() >= new Date(sch.agreed_kickoff_at).getTime()) {
        setStatus("Bring KO forward must be earlier than the agreed kick-off.", true);
        return;
      }
      if (
        !confirm(
          `Request Bring KO forward to ${formatKickoffPair(iso, homeTz, awayTz)}? Opponent must confirm. No reschedule allowance is used.`
        )
      ) {
        return;
      }
      playNowBtn.disabled = true;
      setStatus("Sending Bring KO forward request…");
      const res = await requestMutualOverridePlayNow(fixtureId, iso);
      if (!res.ok) {
        setStatus(res.msg, true);
        playNowBtn.disabled = false;
        return;
      }
      setStatus("Request sent — waiting for opponent to confirm.");
      await reload();
    };
  }

  const newTimeBtn = document.getElementById("newTimeMutualBtn");
  if (newTimeBtn) {
    newTimeBtn.onclick = async () => {
      if (!mutualSelectedKickoff) return;
      if (
        !confirm(
          "Request this new kick-off? Your opponent must confirm. No reschedule allowance is used."
        )
      ) {
        return;
      }
      newTimeBtn.disabled = true;
      setStatus("Sending new-time request…");
      const res = await requestMutualOverrideNewTime(fixtureId, mutualSelectedKickoff);
      if (!res.ok) {
        setStatus(res.msg, true);
        newTimeBtn.disabled = false;
        return;
      }
      setStatus("Request sent — waiting for opponent to confirm.");
      await reload();
    };
  }

  wireMutualPendingButtons();
}

async function applyCheckinSquadGate(fixtureId) {
  const gate = document.getElementById("checkInSquadGate");
  const checkInBtn = document.getElementById("checkInBtn");
  if (!gate) return;

  const res = await loadMatchdayCheckinReadiness(fixtureId);
  if (!res.ok || !res.data) return;

  const issues = Array.isArray(res.data.issues) ? res.data.issues.filter(Boolean) : [];
  if (res.data.ok || !issues.length) {
    gate.style.display = "none";
    return;
  }

  gate.style.display = "block";
  gate.innerHTML = `<b>Matchday squad not ready for check-in.</b> ${issues[0]} <a href="${matchdayFixHref(fixtureId)}" style="color:var(--gpsl-accent, #ff9900);">Open Match Day and fix squad</a>.`;
  if (checkInBtn) {
    checkInBtn.disabled = true;
    checkInBtn.title = issues[0];
  }
}

function render() {
  const root = document.getElementById("scheduleRoot");
  const meta = document.getElementById("scheduleMeta");
  const discord = document.getElementById("discordHint");

  if (!ctx || !root) return;

  const f = ctx.fixture;
  const sch = ctx.schedule;
  const pending = ctx.pending_proposal;
  const monthLabel = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month;

  if (discord) {
    const showDiscord =
      sch.status !== "agreed" &&
      f.status === "scheduled" &&
      !f.is_forfeit;
    discord.hidden = !showDiscord;
    if (showDiscord) void fillDiscordOpponentTag(f);
  }

  if (f.status === "played" || f.is_forfeit) {
    root.innerHTML = `
      <div class="panel">
        <div class="fixture-head">${fixtureTitle(f)}</div>
        <p class="status-agreed">${f.is_forfeit ? "<b>Forfeit</b> — result recorded." : "<b>Played</b>."}</p>
        <div class="actions">
          <a href="fixtures.html" class="button secondary" style="text-decoration:none;display:inline-block;">Fixtures</a>
        </div>
      </div>
    `;
    return;
  }

  if (ctx.manual_black_box === true) {
    if (discord) discord.hidden = true;
    root.innerHTML = `
      <div class="panel">
        <div class="fixture-head">${fixtureTitle(f)}</div>
        <p class="status-agreed"><b>Manual arrange</b> — both clubs have GPSL match system OFF.</p>
        <p class="meta">Arrange off-site. No propose / reply deadlines on this fixture. Play and enter the result on Match Day during the GPSL month. Still unplayed at month lock → mutual forfeit (0 pts each) + ₿2.5m each.</p>
        <div class="actions">
          <a href="${`matchday.html?fixture=${encodeURIComponent(String(f.id))}`}" class="button" style="text-decoration:none;display:inline-block;">Match Day</a>
          <a href="fixtures.html" class="button secondary" style="text-decoration:none;display:inline-block;">Fixtures</a>
          <a href="owner_details.html" class="button secondary" style="text-decoration:none;display:inline-block;">Owner Details</a>
        </div>
      </div>
    `;
    return;
  }

  const newOwnerGrace = ctx.new_owner_arrange_grace;
  if (
    newOwnerGrace &&
    sch.status !== "agreed" &&
    !sch.agreed_kickoff_at
  ) {
    if (discord) discord.hidden = true;
    const fromLabel =
      newOwnerGrace.arrange_from_label ||
      newOwnerGrace.arrangeFromLabel ||
      "the following GPSL month";
    const playLabel =
      newOwnerGrace.play_month_label ||
      newOwnerGrace.playMonthLabel ||
      monthLabel;
    const clubBit = newOwnerGrace.club_short || newOwnerGrace.clubShort || "";
    root.innerHTML = `
      <div class="panel" style="border-color:#3a5a7a;background:#0c1824;">
        <div class="fixture-head">${fixtureTitle(f)}</div>
        <p class="status-agreed"><b>New-owner grace</b> — match arrangement deferred.</p>
        <p class="meta">
          ${clubBit ? `<b>${escapeHtmlLite(clubBit)}</b> took` : "A club took"} charge during
          <b>${escapeHtmlLite(playLabel)}</b>. Propose / reply / Discord lock stay closed until
          <b>${escapeHtmlLite(fromLabel)}</b>.
        </p>
        <div class="actions">
          <a href="fixtures.html" class="button secondary" style="text-decoration:none;display:inline-block;">Fixtures</a>
          <a href="club_fixtures.html" class="button secondary" style="text-decoration:none;display:inline-block;">My fixtures</a>
        </div>
      </div>
    `;
    return;
  }

  if (sch.status === "agreed" && sch.agreed_kickoff_at) {
    renderAgreedPanel(root, f, sch);
    return;
  }

  const intersectionSlots = Array.isArray(ctx.intersection_slots)
    ? ctx.intersection_slots
    : [];
  const ownSlots = Array.isArray(ctx.my_window_slots) ? ctx.my_window_slots : [];
  const oppSlots = Array.isArray(ctx.opp_window_slots) ? ctx.opp_window_slots : [];
  const homeTz = ctx.home_timezone || UK_TZ;
  const awayTz = ctx.away_timezone || UK_TZ;
  const ownerTz = ctx.my_timezone || UK_TZ;
  const oppTz =
    ctx.my_role === "home" ? awayTz : ctx.my_role === "away" ? homeTz : awayTz;
  const oppClubShort =
    ctx.my_role === "home"
      ? f.away_club_short_name
      : ctx.my_role === "away"
        ? f.home_club_short_name
        : f.away_club_short_name;
  // Prefer times free for BOTH clubs (each in their own timezone). Away waiting
  // for home's first propose can still see own slots for reference.
  const isAwayWaitingPreview =
    ctx.my_role === "away" &&
    !(ctx.can_propose_first || ctx.can_respond) &&
    !ctx.pending_proposal;
  const futureIntersection = filterSelectableKickoffSlots(intersectionSlots, ownerTz);
  // Only when server explicitly allows (schedule_poke_no_overlap patch live).
  // Do not infer poke from empty intersection — that looked allowed before the patch.
  const pokeAllowed = ctx.poke_allowed === true;
  const slots = isAwayWaitingPreview ? ownSlots : intersectionSlots;
  const usingCompatibleSlots = !isAwayWaitingPreview;
  const usingPoke =
    !isAwayWaitingPreview && pokeAllowed && futureIntersection.length === 0;
  const pokePatchPending =
    !isAwayWaitingPreview &&
    futureIntersection.length === 0 &&
    ctx.poke_allowed == null;
  const selectableSlots = filterSelectableKickoffSlots(slots, ownerTz);
  const pastHidden = slots.length - selectableSlots.length;
  const selectableOppSlots = filterSelectableKickoffSlots(oppSlots, ownerTz);
  const selectableOwnSlots = filterSelectableKickoffSlots(ownSlots, ownerTz);
  const usedIsoSet = priorProposedKickoffSet(ctx);
  // Exact mutual kick-offs (both free) — green; never retag as compromise
  const exactMatchIsoSet = new Set(
    (futureIntersection || []).map(kickoffIsoKey)
  );
  // Novel midpoints only (not already on either owner's list / not exact matches)
  const compromiseCandidates = buildCompromiseMidpointSlots(
    selectableOwnSlots,
    selectableOppSlots,
    { ownerTimezone: ownerTz, excludeIsoSet: usedIsoSet }
  );
  const compromiseMetaByIso = new Map(
    compromiseCandidates.map((c) => [kickoffIsoKey(c.iso), c])
  );
  const responseLine = formatResponseDeadlineLine(ctx.response_deadline, myClub.short);
  const responseHtml = responseLine
    ? `<p class="meta" style="color:${ctx.response_deadline?.overdue && ctx.response_deadline?.my_turn ? "#f88" : "#fc6"};">${responseLine}</p>`
    : "";

  if (meta) {
    const comp = formatFixtureCompetition(f);
    const roleText = ctx.my_role === "home" ? "You are the home club" : ctx.my_role === "away" ? "You are the away club" : "";
    const tzLine = `Home ${tzDisplayName(homeTz)} · Away ${tzDisplayName(awayTz)}`;
    meta.textContent = [comp, monthLabel, roleText, tzLine, formatOwnerNowLine(ownerTz)]
      .filter(Boolean)
      .join(" · ");
  }

  let pendingHtml = "";
  if (pending) {
    const fromOpponent = pending.proposed_by_club_short_name !== myClub.short;
    const pendingStillValid = isSelectableKickoffSlot(pending.kickoff_at, ownerTz);
    const pendingInMySlots = selectableOwnSlots.some(
      (iso) => String(iso) === String(pending.kickoff_at)
    );
    const pokeIncomingNote =
      fromOpponent &&
      pokeAllowed &&
      !pendingInMySlots &&
      pendingStillValid
        ? `<p class="meta" style="color:#fc6;">This looks like an <b>availability poke</b> (outside mutual weekly slots). Accept if you can make it, counter with another time, or update your availability on Owner Details.</p>`
        : "";
    pendingHtml = `
      <div class="panel">
        <h2>Pending proposal</h2>
        ${responseHtml}
        <p class="status-pending">
          <b>${fullClubName(pending.proposed_by_club_short_name)}</b> proposed
          <span class="kickoff-line">${formatKickoffPair(pending.kickoff_at, homeTz, awayTz)}</span>
        </p>
        ${pokeIncomingNote}
        ${unavailablePanelHtml(f)}
        ${
          !pendingStillValid
            ? '<p class="meta" style="color:#f88;">This time has passed — ask your opponent to counter-propose a future slot.</p>'
            : fromOpponent && ctx.can_respond
              ? `<div class="actions">
                  <button type="button" id="acceptBtn" class="button">Accept this time</button>
                </div>`
              : "<p class=\"meta\">Waiting for your opponent to respond.</p>"
        }
      </div>
    `;
  }

  const canPick =
    (ctx.can_propose_first || ctx.can_respond) && ctx.my_has_manager !== false;
  // Show midpoints under exact matches (poke panel has its own list)
  const showCompromiseRow =
    canPick &&
    !isAwayWaitingPreview &&
    compromiseCandidates.length > 0 &&
    !usingPoke;

  const noManagerBanner =
    ctx.my_has_manager === false
      ? `<div class="panel" style="border-color:#662222;background:#1a0a0a;">
          <p style="margin:0;color:#f88;">
            <b>No manager signed</b> — you cannot arrange kick-off times or play fixtures until you hire one from the
            <a href="manager_listings.html" style="color:var(--gpsl-accent, #ff9900);">Manager Transfer Market</a>
            (bidding while vacant is fine; scheduling unlocks once they are signed).
          </p>
        </div>`
      : "";

  const proposeLabel = ctx.can_propose_first
    ? "Propose kick-off"
    : ctx.can_respond
      ? "Counter-propose"
      : "Suggest another time";

  const waitingForHomeHtml =
    !canPick &&
    !pending &&
    sch.status === "unscheduled" &&
    ctx.my_role === "away" &&
    ctx.my_has_manager !== false
      ? `<p class="meta" style="margin-top:12px;">
          <b>${fullClubName(f.home_club_short_name)}</b> (home) must propose first.
          You will get an <a href="inbox.html" style="color:var(--gpsl-accent, #ff9900);">Inbox</a> message to accept or counter-propose.
        </p>`
      : "";

  const holidayEnd = holidayCorridorEndLabel();
  const propMonth = ctx.is_holiday_early
    ? holidayEnd &&
      String(holidayEnd).toLowerCase() !==
        String(GPSL_MONTH_LABELS[ctx.fixture?.gpsl_month] || ctx.fixture?.gpsl_month || "").toLowerCase()
      ? `now through ${holidayEnd}`
      : holidayEnd || "this holiday corridor"
    : ctx.is_catch_up && holidayEnd
      ? `through ${holidayEnd}`
      : ctx.proposal_window?.gpsl_month && GPSL_MONTH_LABELS[ctx.proposal_window.gpsl_month]
        ? GPSL_MONTH_LABELS[ctx.proposal_window.gpsl_month]
        : ctx.is_catch_up
          ? "the current GPSL month"
          : "this GPSL month";

  const slotCountLine =
    selectableSlots.length === slots.length
      ? `${selectableSlots.length} slot${selectableSlots.length === 1 ? "" : "s"} in ${propMonth}`
      : `${selectableSlots.length} future slot${selectableSlots.length === 1 ? "" : "s"} (${pastHidden} past slot${pastHidden === 1 ? "" : "s"} hidden for your timezone)`;

  const isAwayWaiting = ctx.my_role === "away" && !canPick;
  const slotIntro = isAwayWaiting
    ? `Waiting for <b>${fullClubName(f.home_club_short_name)}</b> (home) to propose first — slot buttons below are for reference only and won’t select. Once they propose you can accept or counter (${slotCountLine}). If you already agreed off-site, use the <b>Agreed on Discord</b> tab.`
      : usingPoke
      ? `No mutual times this window. <b>Poke</b> a kick-off — use opponent availability, a <b>compromise</b> (their time, yours, or midpoint when under 2h apart), or any free date/time. Already-suggested times are greyed out. Same accept / counter / reply rules after you send.`
      : ctx.can_respond
        ? `Accept the proposed time above, or counter with another time free for <b>both</b> clubs in your local timezones (${slotCountLine}). Already-suggested times in this arrangement are greyed out.`
        : usingCompatibleSlots
          ? `Pick a kick-off that is free for <b>both</b> clubs (each availability is in that owner’s timezone; times below are shown in yours). <b style="color:#a8e06a;">Green = exact match</b> (both free). Nearby exclusive times under 2 hours apart appear as <b style="color:#9ec0ff;">blue compromises</b> (meet them, meet you, and midpoint if novel). Already-suggested times are greyed out (${slotCountLine}).`
          : `Pick a 30-minute block from available times (${slotCountLine}). Already-suggested times are greyed out.`;

  const emptySlotsMsg = usingPoke
    ? ""
    : pokePatchPending
      ? '<p class="meta" style="color:#fc6;">No overlapping weekly times. Availability poke is not enabled on the server yet — both clubs need shared weekly slots on <a href="owner_details.html" style="color:var(--gpsl-accent, #ff9900);">Owner Details</a>, or agree on Discord.</p>'
      : !selectableSlots.length
        ? slots.length
          ? '<p class="meta" style="color:#f88;">All listed slots are in the past for your timezone — update availability for later weeks or wait for the next GPSL month.</p>'
          : usingCompatibleSlots
            ? ctx.poke_allowed === false
              ? '<p class="meta" style="color:#f88;">No overlapping times this window — both clubs need weekly availability on <a href="owner_details.html" style="color:var(--gpsl-accent, #ff9900);">Owner Details</a> that share a common kick-off (or free a booked time). Poke is only available when the server reports no mutual slots.</p>'
              : '<p class="meta" style="color:#f88;">No overlapping times this window — both clubs need weekly availability on <a href="owner_details.html" style="color:var(--gpsl-accent, #ff9900);">Owner Details</a> in their own timezones that share a common world kick-off (or free a time already booked).</p>'
            : '<p class="meta" style="color:#f88;">No slots in this window — set weekly availability on <a href="owner_details.html" style="color:var(--gpsl-accent, #ff9900);">Owner Details</a>, or free a time already booked for another match.</p>'
        : "";

  const pokePanelHtml = usingPoke && canPick
    ? `
      <div class="poke-panel" id="pokePanel">
        <h3 class="poke-heading">Opponent availability · ${escapeHtmlLite(
          fullClubName(oppClubShort) || oppClubShort || "Opponent"
        )} (${escapeHtmlLite(tzDisplayName(oppTz))})</h3>
        <p class="meta">Shown in <b>your</b> timezone so you can compare with your own slots (their local clock is on the second line). Times within <b>2 hours</b> of one of yours are colour‑graded: <b style="color:#8f8;">green = closest</b>, through yellow, to <b style="color:#f88;">red = nearer 2h</b>. Click one to start from it, pick a <b>compromise</b> below, or enter any free date/time. Times already suggested in this arrangement are greyed out.</p>
        <p class="meta poke-near-note" id="pokeNearNote" hidden></p>
        <div class="slot-list" id="oppSlotList"></div>
        ${
          selectableOppSlots.length
            ? ""
            : `<p class="meta" style="color:#fc6;">They have no free slots in this window — ask them to set weekly availability on Owner Details, or poke any valid GPSL time anyway.</p>`
        }
        <h3 class="poke-heading">Compromise suggestions (under 2h apart)</h3>
        <p class="meta">Blue chips: <b>their exclusive time</b>, <b>yours</b>, and a <b>midpoint</b> if neither already has it. Exact mutuals stay green above.</p>
        <div class="slot-list" id="compromiseSlotList"></div>
        <h3 class="poke-heading">Your availability (comparison)</h3>
        <div class="slot-list" id="ownSlotList"></div>
        ${
          selectableOwnSlots.length
            ? ""
            : `<p class="meta" style="color:#fc6;">You have no free slots listed — still free to poke a time, or <a href="owner_details.html" style="color:var(--gpsl-accent, #ff9900);">set availability</a>.</p>`
        }
        <h3 class="poke-heading">Poke date &amp; time (${escapeHtmlLite(
          tzDisplayName(ownerTz)
        )})</h3>
        <p class="meta">Any future time in the GPSL month window. Snapped to a UK 30‑minute kick-off boundary. Already-suggested times are blocked.</p>
        <div class="poke-free-row">
          <input type="datetime-local" id="pokeDateTime" step="1800" />
          <button type="button" id="pokeUseBtn" class="button secondary">Use this time</button>
        </div>
        <p class="meta" id="pokePreview" hidden></p>
        <div class="actions">
          <button type="button" id="proposeBtn" class="button" disabled>${
            ctx.can_respond ? "Send poke counter" : "Send poke"
          }</button>
        </div>
      </div>`
    : "";

  const mo = ctx.mutual_override;
  const showDiscordTab = ctx.my_has_manager !== false && !mo;
  const mutualPendingHtml =
    mo && ctx.my_has_manager !== false
      ? mutualPendingPanelHtml(mo, homeTz, awayTz)
      : "";

  const gpslSlotsHeading = isAwayWaiting
    ? "Your availability (for reference)"
    : usingPoke
      ? "No mutual slots — poke a time"
      : usingCompatibleSlots
        ? "Kick-off times both clubs can play"
        : "Available slots";

  const gpslSlotBody = `
      <h2>${showDiscordTab ? "GPSL Match Scheduling" : gpslSlotsHeading}</h2>
      ${
        showDiscordTab
          ? `<p class="meta">${
              isAwayWaiting
                ? "Normal GPSL flow — home proposes from times free for both clubs; you can accept or counter later."
                : usingPoke
                  ? "No overlapping weekly times — send an availability poke (free date/time). Opponent still accepts or counters here; Discord remains an off-site option."
                  : usingCompatibleSlots
                    ? "Normal GPSL flow — pick a kick-off free for both clubs (each owner’s availability in their timezone), then propose or counter."
                    : "Normal GPSL flow — pick a 30-minute block from available times, then propose."
            }</p>`
          : ""
      }
      <p class="meta">${slotIntro}</p>
      ${emptySlotsMsg}
      ${
        usingPoke
          ? pokePanelHtml || waitingForHomeHtml
          : `<div class="slot-list" id="slotList"></div>
      ${
        showCompromiseRow
          ? `<h3 class="poke-heading" style="margin-top:14px;">Compromise suggestions (under 2h apart)</h3>
        <p class="meta">You each have a nearby time the other doesn’t. Blue chips offer <b>their time</b>, <b>your time</b>, and a <b>midpoint</b> (if nobody already has it). Green above stays exact mutual only — e.g. both free 18:30 stays green; 18:00 (them only) and 19:00 (you only) can appear blue.</p>
        <div class="slot-list" id="compromiseSlotList"></div>`
          : ""
      }
      ${
        canPick && (selectableSlots.length || showCompromiseRow)
          ? `<div class="actions">
              <button type="button" id="proposeBtn" class="button" disabled>${proposeLabel}</button>
            </div>`
          : waitingForHomeHtml
      }`
      }
  `;

  const manualNoteHtml = `
    <p class="schedule-manual-note">
      <b>Preferred:</b> GPSL Match Scheduling (propose / accept / counter).
      ${
        showDiscordTab
          ? "<b>Alternative:</b> Agreed on Discord tab if you already picked a time off-site (both still confirm here)."
          : ""
      }
      <b>Manual arrange</b> (fully off-site, no clocks) only when
      <b>both</b> owners have <b>GPSL match system OFF</b> on
      <a href="owner_details.html">Owner Details</a>.
    </p>
  `;

  const schedulingTabsHtml =
    ctx.my_has_manager === false
      ? ""
      : showDiscordTab
        ? `<div class="panel schedule-mode-panel">
      ${manualNoteHtml}
      <div class="schedule-tabs" role="tablist" aria-label="Scheduling mode">
        <button type="button" class="schedule-tab active" data-tab="gpsl" role="tab" aria-selected="true" aria-controls="tabGpsl" id="tabBtnGpsl">GPSL Match Scheduling</button>
        <button type="button" class="schedule-tab" data-tab="discord" role="tab" aria-selected="false" aria-controls="tabDiscord" id="tabBtnDiscord">Agreed on Discord scheduling</button>
      </div>
      <div class="schedule-tab-pane" id="tabGpsl" role="tabpanel" aria-labelledby="tabBtnGpsl">
        ${gpslSlotBody}
      </div>
      <div class="schedule-tab-pane discord-pane" id="tabDiscord" role="tabpanel" aria-labelledby="tabBtnDiscord" hidden>
        ${discordLockPanelBodyHtml()}
      </div>
    </div>`
        : `<div class="panel">
      ${manualNoteHtml}
      ${gpslSlotBody}
    </div>`;

  const alreadyPlayedHtml = alreadyPlayedPanelHtml();

  root.innerHTML = `
    ${catchUpBannerHtml()}
    ${holidayEarlyBannerHtml()}
    ${noManagerBanner}
    <div class="panel">
      <div class="fixture-head">${fixtureTitle(f)}</div>
      ${timezoneComparePanelHtml(f, homeTz, awayTz, ownerTz)}
      ${unavailablePanelHtml(f)}
      ${responseHtml}
      ${deadlineBoxHtml(f)}
      ${
        ctx.my_has_manager !== false &&
        (ctx.allowances?.can_replay_reset || ctx.allowances?.can_catch_up_reset)
          ? `<div class="actions">
              <button type="button" id="catchUpResetBtn" class="button secondary">${
                ctx.allowances?.can_replay_reset
                  ? "Pick new time to play this month"
                  : "Reset catch-up scheduling"
              }</button>
            </div>`
          : ""
      }
    </div>
    ${alreadyPlayedHtml}
    ${mutualPendingHtml}
    ${ctx.my_has_manager === false ? "" : pendingHtml}
    ${schedulingTabsHtml}
  `;

  if (alreadyPlayedHtml) {
    wireAlreadyPlayedButtons();
  }
  if (showDiscordTab) {
    wireScheduleModeTabs("gpsl");
    wireDiscordLockPanel(
      usingPoke ? ownSlots : slots,
      homeTz,
      awayTz,
      ownerTz,
      usedIsoSet
    );
  }
  if (mutualPendingHtml) {
    wireMutualPendingButtons();
  }

  const slotList = document.getElementById("slotList");
  if (slotList) {
    appendKickoffSlotButtons(slotList, slots, {
      homeTz,
      awayTz,
      ownerTz,
      usedIsoSet,
      exactMatchIsoSet: usingCompatibleSlots ? exactMatchIsoSet : null,
      compromiseMetaByIso: null, // mutual list = exact matches only (green)
      onSelect: canPick
        ? (iso, btn, list) => {
            if (usedIsoSet.has(kickoffIsoKey(iso))) return;
            selectedKickoff = iso;
            document
              .querySelectorAll("#slotList .slot-btn, #compromiseSlotList .slot-btn")
              .forEach((b) => b.classList.remove("selected"));
            btn.classList.add("selected");
            const proposeBtn = document.getElementById("proposeBtn");
            if (proposeBtn) proposeBtn.disabled = false;
          }
        : null, // reference-only when waiting for home (unless you opened the drop)
    });
    if (!canPick && selectableSlots.length) {
      const note = document.createElement("p");
      note.className = "meta";
      note.style.color = "#fc6";
      note.style.marginTop = "8px";
      note.innerHTML = isAwayWaiting
        ? "Clicks on these times are ignored until home proposes (or use <b>Agreed on Discord</b>)."
        : "You can’t propose from this club right now.";
      slotList.insertAdjacentElement("afterend", note);
    }
  }

  if (usingPoke && canPick) {
    wirePokePanel({
      homeTz,
      awayTz,
      ownerTz,
      oppTz,
      selectableOppSlots,
      selectableOwnSlots,
      usedIsoSet,
    });
  } else if (showCompromiseRow) {
    const compromiseList = document.getElementById("compromiseSlotList");
    if (compromiseList) {
      appendKickoffSlotButtons(
        compromiseList,
        compromiseCandidates.map((c) => c.iso),
        {
          homeTz,
          awayTz,
          ownerTz,
          usedIsoSet,
          compromiseMetaByIso,
          onSelect: (iso, btn, list) => {
            if (usedIsoSet.has(kickoffIsoKey(iso))) return;
            selectedKickoff = iso;
            document
              .querySelectorAll("#slotList .slot-btn, #compromiseSlotList .slot-btn")
              .forEach((b) => b.classList.remove("selected"));
            btn.classList.add("selected");
            const proposeBtn = document.getElementById("proposeBtn");
            if (proposeBtn) proposeBtn.disabled = false;
          },
        }
      );
    }
  }

  const proposeBtn = document.getElementById("proposeBtn");
  if (proposeBtn) {
    proposeBtn.onclick = async () => {
      if (!selectedKickoff) return;
      if (usedIsoSet.has(kickoffIsoKey(selectedKickoff))) {
        setStatus(
          "That kick-off was already suggested in this arrangement — pick a different time.",
          true
        );
        return;
      }
      proposeBtn.disabled = true;
      setStatus(usingPoke ? "Sending poke…" : "Sending proposal…");
      const res = await proposeKickoff(fixtureId, selectedKickoff);
      if (!res.ok) {
        setStatus(res.msg, true);
        proposeBtn.disabled = false;
        return;
      }
      setStatus(
        usingPoke
          ? "Poke sent — opponent can accept or counter (reply clock running)."
          : "Proposal sent — check your inbox."
      );
      await reload();
    };
  }

  const catchUpResetBtn = document.getElementById("catchUpResetBtn");
  if (catchUpResetBtn) {
    catchUpResetBtn.onclick = async () => {
      if (!confirm(replayResetConfirmMessage(ctx.allowances))) return;
      catchUpResetBtn.disabled = true;
      const res = await catchUpResetSchedule(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        catchUpResetBtn.disabled = false;
        return;
      }
      setStatus("Catch-up reset — propose a new time in the current GPSL month.");
      await reload();
    };
  }

  const acceptBtn = document.getElementById("acceptBtn");
  if (acceptBtn && pending && isSelectableKickoffSlot(pending.kickoff_at, ownerTz)) {
    acceptBtn.onclick = async () => {
      acceptBtn.disabled = true;
      setStatus("Accepting…");
      const res = await acceptProposal(pending.id);
      if (!res.ok) {
        setStatus(res.msg, !res.soft);
        acceptBtn.disabled = false;
        if (res.soft) await reload();
        return;
      }
      setStatus("Kick-off agreed.");
      await reload();
    };
  }
}

async function reload() {
  ctx = await loadScheduleContext(fixtureId);
  try {
    const { data: bb } = await supabase.rpc("fixture_is_manual_black_box", {
      p_fixture_id: fixtureId,
    });
    if (ctx && typeof ctx === "object") ctx.manual_black_box = bb === true;
  } catch {
    if (ctx && typeof ctx === "object") ctx.manual_black_box = false;
  }
  fixtureUnavailable = await loadFixtureUnavailable(supabase, fixtureId);
  const { data: dl, error: dlErr } = await supabase.rpc("match_schedule_fixture_deadlines", {
    p_fixture_id: fixtureId,
  });
  deadlines = dlErr ? null : dl;
  selectedKickoff = null;
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  fixtureId = parseFixtureId();
  if (!fixtureId) {
    const root = document.getElementById("scheduleRoot");
    if (root) {
      root.innerHTML = `<div class="panel">
        <p>Pick a fixture to arrange its kick-off.</p>
        <div class="actions">
          <a href="club_fixtures.html" class="button" style="text-decoration:none;display:inline-block;">My club fixtures</a>
          <a href="dashboard.html#matchdayChecklist" class="button secondary" style="text-decoration:none;display:inline-block;">Matchday checklist</a>
        </div>
      </div>`;
    }
    return;
  }

  await initGlobal();
  await loadClubsMap();
  setSeasonCalendarMonths(await loadSeasonCalendarMonths(supabase));

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClub.short = club?.ShortName || null;

  if (!myClub.short) {
    setStatus("No club linked to this account.", true);
    return;
  }

  try {
    await reload();
  } catch (err) {
    const msg = err.message || String(err);
    setStatus(
      /match_schedule_fixture_context|fixture_check_in|fixture_mutual_override/.test(msg)
        ? "Match scheduling is unavailable right now — please tell the league admin."
        : msg,
      true
    );
  }
});
