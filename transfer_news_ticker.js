/**
 * Transfer news ticker — gold/black brand + RTL marquee under nav actions.
 * Active GPSL months: June, July, August, January.
 *
 * Test: dashboard.html?transfer_news_test=august
 */

import { supabase } from "./supabase_client.js";

const REFRESH_MS = 120_000;
const WINDOW_MONTHS = new Set(["june", "july", "august", "january"]);

let __refreshTimer = null;
let __stories = [];

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

function demoStories(month) {
  const label = month ? String(month).toUpperCase() : "WINDOW";
  return [
    {
      id: "demo-window",
      kind: "window",
      headline: `Transfer window live — ${label}`,
      body: "",
      href: "transfer_center.html",
    },
    {
      id: "demo-1",
      kind: "transfer",
      headline: "DONE DEAL — Demo Striker",
      body: "Arsenal → Chelsea · ₿ 45,000,000",
      href: "transfer_center.html",
    },
    {
      id: "demo-2",
      kind: "draft",
      headline: "DRAFT DEAL — Demo Keeper joins Liverpool",
      body: "Draft auction",
      href: "transfer_center.html",
    },
    {
      id: "demo-3",
      kind: "transfer",
      headline: "DONE DEAL — Demo Midfielder",
      body: "Free agent → Spurs · ₿ 12,500,000",
      href: "transfer_center.html",
    },
    {
      id: "demo-4",
      kind: "transfer",
      headline: "DONE DEAL — Demo Winger",
      body: "Everton → City · ₿ 28,000,000",
      href: "transfer_center.html",
    },
  ];
}

function storyLabel(story) {
  const h = String(story?.headline || "").trim();
  const b = String(story?.body || "").trim();
  if (h && b) return `${h}  ·  ${b}`;
  return h || b || "Transfer news";
}

/** Sit on the row directly under Calendar / Natter / … / Logout. */
export function ensureTransferNewsStripMount() {
  const nav = document.getElementById("nav");
  if (!nav) return null;

  let el = document.getElementById("transferNewsStrip");
  if (!el) {
    el = document.createElement("div");
    el.id = "transferNewsStrip";
    el.className = "transfer-news-strip";
    el.setAttribute("aria-live", "off");
    el.hidden = true;
  }

  const bar = nav.querySelector(".gpsl-nav-bar");
  const menusRow = nav.querySelector(".gpsl-nav-row-menus");
  const schedule = document.getElementById("seasonScheduleStrip");

  if (bar && menusRow) {
    // Immediately under the menus/actions row, above season schedule
    if (schedule && schedule.parentNode === bar) {
      bar.insertBefore(el, schedule);
    } else if (menusRow.nextSibling) {
      bar.insertBefore(el, menusRow.nextSibling);
    } else {
      bar.appendChild(el);
    }
  } else if (el.parentNode !== nav) {
    if (schedule && schedule.parentNode === nav) {
      nav.insertBefore(el, schedule);
    } else {
      nav.appendChild(el);
    }
  }

  return el;
}

function renderMarqueeTrack(stories) {
  const items = stories
    .map((s) => {
      const href = escapeHtml(s.href || "transfer_center.html");
      const kind = escapeHtml(s.kind || "transfer");
      const label = escapeHtml(storyLabel(s));
      return (
        `<a class="tn-item tn-kind-${kind}" href="${href}">` +
        `<span class="tn-bullet" aria-hidden="true">◆</span>` +
        `<span class="tn-text">${label}</span>` +
        `</a>`
      );
    })
    .join('<span class="tn-sep" aria-hidden="true">|</span>');

  // Duplicate for seamless loop
  return (
    `<div class="tn-track">` +
    `<div class="tn-seq">${items}</div>` +
    `<div class="tn-seq" aria-hidden="true">${items}</div>` +
    `</div>`
  );
}

function paintMarquee(stories) {
  const el = document.getElementById("transferNewsStrip");
  if (!el) return;

  if (!stories.length) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }

  const duration = Math.max(18, stories.length * 7);

  el.innerHTML =
    `<div class="tn-shell">` +
    `<div class="tn-brand" aria-hidden="true">` +
    `<span class="tn-brand-transfer">TRANSFER</span>` +
    `<span class="tn-brand-chevron">&gt;&gt;</span>` +
    `<span class="tn-brand-news">NEWS</span>` +
    `</div>` +
    `<div class="tn-viewport">` +
    renderMarqueeTrack(stories) +
    `</div>` +
    `</div>`;

  const track = el.querySelector(".tn-track");
  if (track) {
    track.style.setProperty("--tn-duration", `${duration}s`);
  }

  el.hidden = false;
}

function showStories(stories) {
  __stories = (stories || []).slice(0, 5);
  paintMarquee(__stories);
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
