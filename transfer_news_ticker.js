/**
 * Sky-style transfer news ticker under nav (May–July GPSL months).
 * Max 5 stories, rotating. Data: gpsl_transfer_news_feed().
 */

import { supabase } from "./supabase_client.js";

const ROTATE_MS = 6500;
const REFRESH_MS = 120_000;

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

    const schedule = document.getElementById("seasonScheduleStrip");
    if (schedule && schedule.parentNode === nav) {
      schedule.insertAdjacentElement("afterend", el);
    } else {
      nav.appendChild(el);
    }
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

function testForceMonth() {
  try {
    const q = new URLSearchParams(window.location.search || "");
    const raw = (q.get("transfer_news_test") || "").toLowerCase().trim();
    if (raw === "may" || raw === "june" || raw === "july") return raw;
    if (raw === "1" || raw === "true") return "june";
  } catch {
    /* ignore */
  }
  return null;
}

export async function refreshTransferNewsStrip() {
  const el = ensureTransferNewsStripMount();
  if (!el) return;

  try {
    const force = testForceMonth();
    const { data, error } = force
      ? await supabase.rpc("gpsl_transfer_news_feed", { p_force_month: force })
      : await supabase.rpc("gpsl_transfer_news_feed");
    if (error) {
      console.warn("transfer news feed:", error.message);
      el.hidden = true;
      el.innerHTML = "";
      return;
    }

    const stories = Array.isArray(data?.stories) ? data.stories.slice(0, 5) : [];
    if (!data?.visible || !stories.length) {
      __stories = [];
      el.hidden = true;
      el.innerHTML = "";
      if (__rotateTimer) {
        clearInterval(__rotateTimer);
        __rotateTimer = null;
      }
      return;
    }

    __stories = stories;
    __index = 0;
    paintCurrent();
    startRotation();
  } catch (err) {
    console.warn("transfer news strip:", err);
    el.hidden = true;
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
