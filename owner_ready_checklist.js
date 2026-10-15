/**
 * "Ready for August" owner checklist (dashboard).
 * Data: owner_season_ready_checklist() RPC — hidden once GPSL August unlocks.
 */

import { supabase } from "./global.js";

const COLLAPSE_KEY = "gpsl_ready_collapsed";
const GROUP_ORDER = ["Squad", "Club set-up", "Fixtures", "Matchday ready"];

let lastData = null;

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatUk(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function daysUntil(iso) {
  const ms = new Date(iso).getTime() - Date.now();
  if (!Number.isFinite(ms) || ms <= 0) return "";
  const days = Math.floor(ms / 86_400_000);
  if (days >= 1) return `in ${days} day${days === 1 ? "" : "s"}`;
  const hours = Math.max(1, Math.floor(ms / 3_600_000));
  return `in ${hours} hour${hours === 1 ? "" : "s"}`;
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

function injectCss() {
  if (document.getElementById("readyChecklistCss")) return;
  const style = document.createElement("style");
  style.id = "readyChecklistCss";
  style.textContent = `
    .rc-panel { background: var(--club-panel, #1a1a1a); border: 1px solid var(--club-border, #333);
      border-left: 4px solid var(--club-accent, #ff9900); border-radius: 8px; padding: 10px 14px; margin: 0 0 18px; }
    .rc-panel[hidden] { display: none !important; }
    .rc-panel.rc-complete { border-left-color: #3a6; }
    .rc-head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 14px; }
    .rc-head h2 { margin: 0; font-size: 15px; color: var(--club-accent, #ff9900); }
    .rc-complete .rc-head h2 { color: #8d8; }
    .rc-count { font-size: 13px; color: #ffcc66; font-weight: bold; }
    .rc-complete .rc-count { color: #8d8; }
    .rc-bar { flex: 1 1 120px; max-width: 220px; height: 8px; background: #2a2a2a; border-radius: 999px; overflow: hidden; }
    .rc-bar span { display: block; height: 100%; background: linear-gradient(90deg, #cc7a00, #ff9900); }
    .rc-complete .rc-bar span { background: #3a6; }
    .rc-when { font-size: 12px; color: #999; width: 100%; }
    .rc-toggle { margin-left: auto; background: none; border: 1px solid #444; color: #aaa; border-radius: 4px;
      font-size: 11px; padding: 3px 8px; cursor: pointer; }
    .rc-collapsed .rc-body { display: none; }
    .rc-groups { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 10px; margin-top: 10px; }
    .rc-group { background: #141414; border: 1px solid #2a2a2a; border-radius: 6px; padding: 8px 10px; }
    .rc-group h3 { margin: 0 0 6px; font-size: 11px; letter-spacing: 0.05em; text-transform: uppercase; color: #888; }
    .rc-item { display: flex; gap: 8px; align-items: flex-start; padding: 5px 0; border-top: 1px solid #222; font-size: 13px; color: #ddd; }
    .rc-item:first-of-type { border-top: none; }
    .rc-icon { flex: 0 0 18px; text-align: center; font-weight: bold; }
    .rc-item.done .rc-icon { color: #6c6; }
    .rc-item.todo .rc-icon { color: #f66; }
    .rc-item.rec .rc-icon { color: #888; }
    .rc-text { flex: 1; min-width: 0; }
    .rc-detail { font-size: 11px; color: #888; margin-top: 1px; }
    .rc-item.todo .rc-detail { color: #e9a; }
    .rc-item a.rc-go { font-size: 11px; color: #ff9900; white-space: nowrap; align-self: center; }
    .rc-item label { display: flex; gap: 8px; cursor: pointer; flex: 1; }
    .rc-item input[type=checkbox] { margin-top: 2px; accent-color: #ff9900; }
    .rc-foot { font-size: 11px; color: #777; margin-top: 8px; }
  `;
  document.head.appendChild(style);
}

function itemHtml(it) {
  const done = Boolean(it.done);
  const external = /^https?:/i.test(it.href || "");
  const go = it.href
    ? `<a class="rc-go" href="${esc(it.href)}"${external ? ' target="_blank" rel="noopener"' : ""}>${
        it.kind === "tick" ? "Read →" : done ? "View →" : "Fix →"
      }</a>`
    : "";
  if (it.kind === "tick") {
    return `
      <div class="rc-item ${done ? "done" : "todo"}">
        <label>
          <input type="checkbox" data-rc-tick="${esc(it.key)}"${done ? " checked" : ""}>
          <span class="rc-text">${esc(it.label)}</span>
        </label>
        ${go}
      </div>`;
  }
  const cls = done ? "done" : it.kind === "recommended" ? "rec" : "todo";
  const icon = done ? "✓" : it.kind === "recommended" ? "○" : "✗";
  return `
    <div class="rc-item ${cls}">
      <span class="rc-icon" aria-hidden="true">${icon}</span>
      <span class="rc-text">${esc(it.label)}${it.detail ? `<div class="rc-detail">${esc(it.detail)}</div>` : ""}</span>
      ${go}
    </div>`;
}

function render() {
  const section = document.getElementById("seasonReadyPanel");
  if (!section) return;
  const data = lastData;
  if (!data?.visible || !Array.isArray(data.items)) {
    section.hidden = true;
    section.innerHTML = "";
    return;
  }

  const counted = data.items.filter((i) => i.kind !== "recommended");
  const doneCount = counted.filter((i) => i.done).length;
  const total = counted.length;
  const complete = doneCount === total;
  const pct = total ? Math.round((doneCount / total) * 100) : 0;
  const collapsed = isCollapsed();

  const groups = GROUP_ORDER.map((g) => {
    const items = data.items.filter((i) => i.group === g);
    if (!items.length) return "";
    return `<div class="rc-group"><h3>${esc(g)}</h3>${items.map(itemHtml).join("")}</div>`;
  }).join("");

  const when = data.august_unlock_at
    ? `GPSL August opens ${esc(formatUk(data.august_unlock_at))} UK ${esc(daysUntil(data.august_unlock_at))}`
    : "Get these in place before GPSL August opens.";

  section.hidden = false;
  section.className = `rc-panel${complete ? " rc-complete" : ""}${collapsed ? " rc-collapsed" : ""}`;
  section.innerHTML = `
    <div class="rc-head">
      <h2>${complete ? "✓ " : ""}Ready for August</h2>
      <span class="rc-count">${doneCount} / ${total}</span>
      <span class="rc-bar" aria-hidden="true"><span style="width:${pct}%"></span></span>
      <button type="button" class="rc-toggle" aria-expanded="${collapsed ? "false" : "true"}">${collapsed ? "Show" : "Hide"}</button>
      <span class="rc-when">${when}</span>
    </div>
    <div class="rc-body">
      <div class="rc-groups">${groups}</div>
      <div class="rc-foot">Ticks update by themselves as you fix things. This list disappears once GPSL August opens.</div>
    </div>`;

  section.querySelector(".rc-toggle")?.addEventListener("click", () => {
    setCollapsed(!isCollapsed());
    render();
  });
  section.querySelectorAll("[data-rc-tick]").forEach((box) => {
    box.addEventListener("change", () => onTick(box));
  });
}

async function onTick(box) {
  const key = box.dataset.rcTick;
  box.disabled = true;
  const { error } = await supabase.rpc("owner_ready_tick", {
    p_item_key: key,
    p_ticked: box.checked,
    p_fixture_id: null,
  });
  if (error) {
    alert(error.message || "Could not save that tick.");
    box.checked = !box.checked;
    box.disabled = false;
    return;
  }
  const item = lastData?.items?.find((i) => i.key === key);
  if (item) item.done = box.checked;
  render();
}

export async function refreshOwnerReadyChecklist() {
  const { data, error } = await supabase.rpc("owner_season_ready_checklist");
  if (error) {
    console.warn("owner_season_ready_checklist:", error.message);
    lastData = null;
  } else {
    lastData = data;
  }
  render();
}

export function startOwnerReadyChecklist() {
  injectCss();
  refreshOwnerReadyChecklist();
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refreshOwnerReadyChecklist();
  });
}
