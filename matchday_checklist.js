/**
 * Matchday checklist — per-fixture owner tick list (dashboard).
 * Data: dashboard_matchday_checklist() RPC.
 */

import { supabase } from "./global.js";
import { fullClubName } from "./clubs_lookup.js";

const REFRESH_MS = 120_000;
const TICK_MS = 30_000;
const COLLAPSE_KEY = "gpsl_mc_collapsed";

let lastData = null;
let refreshTimer = null;
let tickTimer = null;

const STEP_ICON = {
  done: "✓",
  todo: "●",
  overdue: "!",
  warn: "⚠",
  waiting: "⏳",
  upcoming: "○",
  na: "–",
  missed: "✕",
};

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubLabel(short) {
  return fullClubName(short) || short || "?";
}

export function competitionShortLabel(fx) {
  if (String(fx.competition_type || "").toLowerCase() === "cup") {
    const code = String(fx.cup_code || "").toLowerCase();
    const map = { super8: "Super8", plate: "Plate", shield: "Shield", bowl: "Bowl", league_cup: "League Cup" };
    return `${map[code] || fx.cup_code || "Cup"} R${fx.cup_round ?? "?"}`;
  }
  return `MD${fx.matchday ?? "?"}`;
}

function formatUk(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function relTime(iso) {
  if (!iso) return "";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "";
  const diff = t - Date.now();
  const abs = Math.abs(diff);
  const mins = Math.round(abs / 60000);
  let txt;
  if (mins < 60) txt = `${mins}m`;
  else if (mins < 48 * 60) txt = `${Math.floor(mins / 60)}h ${mins % 60}m`;
  else txt = `${Math.floor(mins / 1440)}d ${Math.floor((mins % 1440) / 60)}h`;
  return diff >= 0 ? `in ${txt}` : `${txt} ago`;
}

function stepDue(step) {
  if (!step?.due_at) return "";
  if (step.state === "done") return formatUk(step.due_at);
  const rel = relTime(step.due_at);
  const past = new Date(step.due_at).getTime() < Date.now();
  if (step.key === "checkin" && step.state === "upcoming") return `opens ${rel}`;
  if (past) return `deadline passed ${rel}`;
  return `due ${rel}`;
}

function stepTitle(step) {
  const bits = [step.label];
  if (step.detail) bits.push(step.detail);
  const due = stepDue(step);
  if (due) bits.push(due);
  return bits.join(" — ");
}

function renderStepPill(step) {
  const state = step.state || "upcoming";
  return `<span class="mc-step mc-${escapeHtml(state)}" title="${escapeHtml(stepTitle(step))}">` +
    `<span class="mc-step-icon" aria-hidden="true">${STEP_ICON[state] || "○"}</span>` +
    `<span class="mc-step-label">${escapeHtml(shortStepName(step.key))}</span></span>`;
}

function shortStepName(key) {
  return {
    schedule: "Kick-off",
    squad: "Squad",
    checkin: "Check-in",
    result: "Result",
    stats: "Stats",
    confirm: "Confirmed",
    video: "Video",
  }[key] || key;
}

function renderActionButton(step, fixtureId) {
  if (!step) return "";
  if (step.key === "checkin" && step.state === "todo") {
    return `<button type="button" class="mc-btn mc-btn-primary" data-mc-checkin="${fixtureId}">Check in</button>`;
  }
  if (step.href === "discord") {
    return step.filename
      ? `<button type="button" class="mc-btn mc-btn-primary" data-mc-copy="${escapeHtml(step.filename)}" title="Copy filename, then post the video in the match videos Discord channel">Copy video filename</button>`
      : "";
  }
  if (!step.href) return "";
  return `<a class="mc-btn mc-btn-primary" href="${escapeHtml(step.href)}">${escapeHtml(step.action || "Open")}</a>`;
}

function renderFlags(flags) {
  if (!Array.isArray(flags) || !flags.length) return "";
  return flags
    .map((f) => {
      const text = escapeHtml(f.text);
      const inner = f.href ? `<a href="${escapeHtml(f.href)}">${text}</a>` : text;
      return `<span class="mc-flag mc-flag-${escapeHtml(f.level || "info")}">${inner}</span>`;
    })
    .join("");
}

function renderFixture(fx) {
  const fid = Number(fx.fixture_id);
  const vs = `${fx.side === "home" ? "vs" : "@"} ${escapeHtml(clubLabel(fx.opponent_short_name))}`;
  const steps = Array.isArray(fx.steps) ? fx.steps : [];
  const next = fx.next_action;
  const nextDetail = next
    ? [next.detail, stepDue(next)].filter(Boolean).join(" · ")
    : "";
  const video = steps.find((s) => s.key === "video");
  const showFilename = video?.filename && ["todo", "warn", "overdue"].includes(video.state);
  let status;
  if (next) {
    status = `<div class="mc-next mc-next-${escapeHtml(next.state)}"><b>${escapeHtml(next.label)}</b>${
      nextDetail ? ` <span class="mc-next-detail">${escapeHtml(nextDetail)}</span>` : ""
    }</div>`;
  } else {
    const waiting = steps.find((s) => s.state === "waiting");
    const upcoming = steps.find((s) => s.state === "upcoming");
    const info = waiting || upcoming;
    status = `<div class="mc-next mc-next-quiet">${
      info ? escapeHtml(stepTitle(info)) : "Nothing to do right now"
    }</div>`;
  }

  return `
    <div class="mc-fixture${fx.needs_you > 0 ? " mc-has-todo" : ""}" data-fixture-id="${fid}">
      <div class="mc-fx-head">
        <span class="mc-fx-comp">${escapeHtml(competitionShortLabel(fx))}</span>
        <a class="mc-fx-vs" href="matchday.html?fixture=${fid}">${vs}</a>
        ${fx.agreed_kickoff_at ? `<span class="mc-fx-ko">${escapeHtml(formatUk(fx.agreed_kickoff_at))}</span>` : ""}
      </div>
      <div class="mc-steps">${steps.map(renderStepPill).join("")}</div>
      ${status}
      ${showFilename ? `<div class="mc-filename">Filename: <code>${escapeHtml(video.filename)}</code></div>` : ""}
      ${fx.flags?.length ? `<div class="mc-flags">${renderFlags(fx.flags)}</div>` : ""}
      ${next ? `<div class="mc-actions">${renderActionButton(next, fid)}</div>` : ""}
    </div>`;
}

function isCollapsed() {
  try {
    return localStorage.getItem(COLLAPSE_KEY) === "1";
  } catch {
    return false;
  }
}

function setCollapsed(v) {
  try {
    localStorage.setItem(COLLAPSE_KEY, v ? "1" : "0");
  } catch {
    /* ignore */
  }
}

function render() {
  const section = document.getElementById("matchdayChecklist");
  if (!section) return;
  const data = lastData;
  const fixtures = Array.isArray(data?.fixtures) ? data.fixtures : [];
  const clubFlags = Array.isArray(data?.flags) ? data.flags : [];

  if (!data?.ok || (!fixtures.length && !clubFlags.length)) {
    section.hidden = true;
    section.innerHTML = "";
    return;
  }
  section.hidden = false;

  const needs = Number(data.needs_you) || 0;
  const open = fixtures.filter((f) => !f.all_done);
  const done = fixtures.filter((f) => f.all_done);
  const month = data.gpsl_month ? data.gpsl_month[0].toUpperCase() + data.gpsl_month.slice(1) : "";
  const lock = data.month_lock_at
    ? `<span class="mc-lock" title="${escapeHtml(formatUk(data.month_lock_at))} UK">Month locks ${escapeHtml(relTime(data.month_lock_at))}</span>`
    : "";

  if (!open.length && !clubFlags.length) {
    section.className = "mc-panel mc-all-done";
    section.innerHTML = `<div class="mc-head"><h2>✓ Matchday checklist</h2><span class="mc-count mc-count-done">All done${month ? ` for ${escapeHtml(month)}` : ""}</span>${lock}</div>`;
    return;
  }

  const collapsed = isCollapsed();
  section.className = `mc-panel${needs > 0 ? " mc-needs" : ""}${collapsed ? " mc-collapsed" : ""}`;
  const countText = needs > 0
    ? `${needs} thing${needs === 1 ? "" : "s"} need${needs === 1 ? "s" : ""} you${month ? ` this month` : ""}`
    : "Nothing needs you right now";

  const doneLine = done.length
    ? `<div class="mc-done-line">✓ All done: ${done
        .map((f) => `${escapeHtml(competitionShortLabel(f))} ${f.side === "home" ? "vs" : "@"} ${escapeHtml(f.opponent_short_name)}`)
        .join(" · ")}</div>`
    : "";

  section.innerHTML = `
    <div class="mc-head">
      <h2>Matchday checklist${month ? ` · ${escapeHtml(month)}` : ""}</h2>
      <span class="mc-count${needs > 0 ? " mc-count-todo" : ""}">${escapeHtml(countText)}</span>
      ${lock}
      <button type="button" class="mc-toggle" aria-expanded="${collapsed ? "false" : "true"}">${collapsed ? "Show" : "Hide"}</button>
    </div>
    <div class="mc-body">
      ${clubFlags.length ? `<div class="mc-flags mc-club-flags">${renderFlags(clubFlags)}</div>` : ""}
      <div class="mc-list">${open.map(renderFixture).join("")}</div>
      ${doneLine}
      <div class="mc-legend">✓ done · ● your move · ⏳ waiting on opponent · ○ later · ! overdue</div>
    </div>`;

  section.querySelector(".mc-toggle")?.addEventListener("click", () => {
    setCollapsed(!isCollapsed());
    render();
  });
  section.querySelectorAll("[data-mc-checkin]").forEach((btn) => {
    btn.addEventListener("click", () => onCheckIn(Number(btn.dataset.mcCheckin), btn));
  });
  section.querySelectorAll("[data-mc-copy]").forEach((btn) => {
    btn.addEventListener("click", () => onCopy(btn));
  });
}

async function onCopy(btn) {
  const text = btn.dataset.mcCopy || "";
  try {
    await navigator.clipboard.writeText(text);
    btn.textContent = "Copied ✓";
  } catch {
    window.prompt("Copy this filename:", text);
  }
  setTimeout(() => {
    btn.textContent = "Copy video filename";
  }, 2000);
}

async function onCheckIn(fixtureId, btn) {
  if (!fixtureId) return;
  btn.disabled = true;
  btn.textContent = "Checking in…";
  const { error } = await supabase.rpc("fixture_check_in", { p_fixture_id: fixtureId });
  if (error) {
    const msg = String(error.message || "");
    if (/matchday squad|saved (starting|matchday) xi|injured or suspended/i.test(msg)) {
      window.location = `matchday.html?fixture=${fixtureId}&fix_checkin_squad=1`;
      return;
    }
    alert(msg || "Could not check in.");
    btn.disabled = false;
    btn.textContent = "Check in";
    return;
  }
  await refreshMatchdayChecklist();
}

export async function fetchMatchdayChecklist() {
  const { data, error } = await supabase.rpc("dashboard_matchday_checklist");
  if (error) {
    console.warn("dashboard_matchday_checklist:", error.message);
    return null;
  }
  return data;
}

export async function refreshMatchdayChecklist() {
  lastData = await fetchMatchdayChecklist();
  render();
}

export function startMatchdayChecklist(clubShortName) {
  const section = document.getElementById("matchdayChecklist");
  if (!section || !clubShortName) {
    if (section) section.hidden = true;
    return;
  }
  refreshMatchdayChecklist().then(() => {
    if (window.location.hash === "#matchdayChecklist") {
      setCollapsed(false);
      render();
      section.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  });
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshMatchdayChecklist, REFRESH_MS);
  if (tickTimer) clearInterval(tickTimer);
  tickTimer = setInterval(render, TICK_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refreshMatchdayChecklist();
  });
}
