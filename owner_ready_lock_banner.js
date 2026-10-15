/**
 * Site-wide warning while the owner's "Ready for August" checklist is incomplete
 * after GPSL August opens (matches locked). Data: owner_ready_lock_status() RPC.
 */

import { supabase } from "./supabase_client.js";

const BANNER_ID = "ownerReadyLockBanner";
const CACHE_KEY = "gpsl_ready_lock_v1";
const CACHE_MS = 60_000;

function readCache() {
  try {
    const raw = sessionStorage.getItem(CACHE_KEY);
    if (!raw) return null;
    const c = JSON.parse(raw);
    if (!c || Date.now() - Number(c.at) > CACHE_MS) return null;
    return c.data;
  } catch {
    return null;
  }
}

function writeCache(data) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), data }));
  } catch {
    /* ignore */
  }
}

export function clearOwnerReadyLockBanner() {
  document.getElementById(BANNER_ID)?.remove();
  try {
    sessionStorage.removeItem(CACHE_KEY);
  } catch {
    /* ignore */
  }
}

function render(data) {
  document.getElementById(BANNER_ID)?.remove();
  if (!data?.locked) return;

  const n = Number(data.missing_count) || 0;
  const onDashboard = /(^|\/)dashboard\.html$/i.test(location.pathname);
  const bar = document.createElement("div");
  bar.id = BANNER_ID;
  bar.setAttribute("role", "alert");
  bar.style.cssText =
    "background:#3a1414;border:1px solid #a33;border-left:5px solid #e33;color:#fdd;" +
    "padding:10px 14px;margin:8px auto;max-width:1200px;border-radius:6px;font-size:14px;line-height:1.4;";
  bar.innerHTML =
    `<strong style="color:#f88">🔒 Matches locked.</strong> ` +
    `Complete your Ready for August checklist before you can check in or play — ` +
    `${n} required item${n === 1 ? "" : "s"} left. Missed check-ins count as no-shows. ` +
    (onDashboard
      ? `<a href="#seasonReadyPanel" style="color:#ff9900;font-weight:bold">See the checklist ↓</a>`
      : `<a href="dashboard.html#seasonReadyPanel" style="color:#ff9900;font-weight:bold">Open the checklist →</a>`);

  const nav = document.getElementById("nav");
  if (nav?.parentNode) {
    nav.insertAdjacentElement("afterend", bar);
  } else {
    document.body.prepend(bar);
  }
}

export async function refreshOwnerReadyLockBanner() {
  const cached = readCache();
  if (cached) {
    render(cached);
    return;
  }
  const { data, error } = await supabase.rpc("owner_ready_lock_status");
  if (error) return;
  writeCache(data);
  render(data);
}
