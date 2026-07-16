/**
 * Sky-style transfer news ticker under nav.
 * Active GPSL months: June, July, August, January (live transfer windows).
 * Max 5 stories, rotating. Data: gpsl_transfer_news_feed().
 *
 * Test:
 *   dashboard.html?transfer_news_test=june
 *   dashboard.html?transfer_news_test=august
 *   dashboard.html?transfer_news_test=january
 */

import { supabase } from "./supabase_client.js";

const ROTATE_MS = 6500;
const REFRESH_MS = 120_000;
const WINDOW_MONTHS = new Set(["june", "july", "august", "january"]);

let __rotateTimer = null;
let __refreshTimer = null;
let __stories = [];
let __index = 0;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function testForceMonth() {
  try {
    const q = new URLSearchParams(window.location.search || "");
    const raw = (q.get("transfer_news_test") || "").toLowerCase().trim();
    if (WINDOW_MONTHS.has(raw)) return raw;
    if (raw === "1" || raw === "true") return "june";
  } catch {
    /* ignore */
  }
  return null;
}

/** Guaranteed UI preview when ?transfer_news_test= is set. */
function demoStories(month) {
  const label = month ? String(month).toUpperCase() : "TRANSFER WINDOW";
  return [
    {
      id: "demo-window",
      kind: "window",
      kicker: "TRANSFER NEWS",
      headline: `Transfer window live — ${label}`,
      body: "Demo preview — draft auctions and free-market deals rotate here.",
      href: "transfer_center.html",
    },
    {
      id: "demo-1",
      kind: "transfer",
      kicker: "TRANSFER NEWS",
      headline: "DONE DEAL — Demo Striker",
      body: "Arsenal → Chelsea · ₿ 45,000,000 · Transfer list (auction)",
      href: "transfer_center.html",
    },
    {
      id: "demo-2",
      kind: "draft",
      kicker: "TRANSFER NEWS",
      headline: "DRAFT DEAL — Demo Keeper joins Liverpool",
      body: "Draft auction",
      href: "transfer_center.html",
    },
    {
      id: "demo-3",
      kind: "transfer",
      kicker: "TRANSFER NEWS",
      headline: "DONE DEAL — Demo Midfielder",
      body: "Free agent → Spurs · ₿ 12,500,000 · Direct offer",
      href: "transfer_center.html",
    },
  ].slice(0, 5);
}

export function ensureTransferNewsStripMount() {
  const nav = document.getElementById("nav");
  if (!nav) return null;

  let el = document.getElementById("transferNewsStrip");
  if (!el) {
    el = document.createElement("div");
    el.id = "transferNewsStrip";
    el.className = "transfer-news-strip";
    el.setAttribute("aria-live", "polite");
    el.hidden = true;
    nav.appendChild(el);
  }
  return el;
}

function renderStory(story, index, total) {
  if (!story) return "";
  const href = escapeHtml(story.href || "transfer_center.html");
  const kicker = escapeHtml(story.kicker || "TRANSFER NEWS");
  const headline = escapeHtml(story.headline || "");
  const body = escapeHtml(story.body || "");
  const kind = escapeHtml(story.kind || "transfer");
  const dots =
    total > 1
      ? `<span class="tn-dots" aria-hidden="true">${Array.from({ length: total }, (_, i) =>
          `<span class="tn-dot${i === index ? " is-on" : ""}"></span>`
        ).join("")}</span>`
      : "";

  return (
    `<a class="tn-inner tn-kind-${kind}" href="${href}">` +
    `<span class="tn-rail">` +
    `<span class="tn-live">LIVE</span>` +
    `<span class="tn-kicker">${kicker}</span>` +
    `</span>` +
    `<span class="tn-copy">` +
    `<span class="tn-headline">${headline}</span>` +
    (body ? `<span class="tn-body">${body}</span>` : "") +
    `</span>` +
    dots +
    `</a>`
  );
}

function paintCurrent() {
  const el = document.getElementById("transferNewsStrip");
  if (!el || !__stories.length) return;
  const i = __index % __stories.length;
  el.innerHTML = renderStory(__stories[i], i, __stories.length);
  el.hidden = false;
}

function startRotation() {
  if (__rotateTimer) {
    clearInterval(__rotateTimer);
    __rotateTimer = null;
  }
  if (__stories.length <= 1) return;
  __rotateTimer = setInterval(() => {
    __index = (__index + 1) % __stories.length;
    paintCurrent();
  }, ROTATE_MS);
}

function showStories(stories) {
  __stories = (stories || []).slice(0, 5);
  __index = 0;
  if (!__stories.length) {
    const el = document.getElementById("transferNewsStrip");
    if (el) {
      el.hidden = true;
      el.innerHTML = "";
    }
    if (__rotateTimer) {
      clearInterval(__rotateTimer);
      __rotateTimer = null;
    }
    return;
  }
  paintCurrent();
  startRotation();
}

export async function refreshTransferNewsStrip() {
  const el = ensureTransferNewsStripMount();
  if (!el) return;

  const force = testForceMonth();

  if (force) {
    try {
      const { data, error } = await supabase.rpc("gpsl_transfer_news_feed", {
        p_force_month: force,
      });
      if (!error && data?.visible && Array.isArray(data.stories) && data.stories.length) {
        showStories(data.stories);
        return;
      }
      if (error) console.warn("transfer news feed (test):", error.message);
    } catch (err) {
      console.warn("transfer news feed (test):", err);
    }
    showStories(demoStories(force));
    return;
  }

  try {
    const { data, error } = await supabase.rpc("gpsl_transfer_news_feed");
    if (error) {
      console.warn("transfer news feed:", error.message);
      showStories([]);
      return;
    }
    const stories = Array.isArray(data?.stories) ? data.stories : [];
    if (!data?.visible || !stories.length) {
      showStories([]);
      return;
    }
    showStories(stories);
  } catch (err) {
    console.warn("transfer news strip:", err);
    showStories([]);
  }
}

export function initTransferNewsStrip() {
  ensureTransferNewsStripMount();
  refreshTransferNewsStrip();

  if (__refreshTimer) return;
  __refreshTimer = setInterval(() => {
    refreshTransferNewsStrip();
  }, REFRESH_MS);
}
