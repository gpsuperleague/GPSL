/**
 * "Next club auction" countdown for waiting-list / pre-club pages.
 *
 * Target = earliest future start from:
 *   • the armed club auction (club_auction_get_state.start_time), or
 *   • the next visible club_auction event in the admin Events planner
 *     (gpsl_planned_events), which may not be switched on yet.
 *
 * Hides itself while the shared draft countdown (armed auction) is showing,
 * so the two clocks never duplicate.
 */
import { supabase } from "./supabase_client.js";

function pad(n) {
  return String(n).padStart(2, "0");
}

function formatRemaining(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const d = Math.floor(total / 86400);
  const h = Math.floor((total % 86400) / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return d > 0 ? `${d}d ${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(h)}:${pad(m)}:${pad(s)}`;
}

function formatWhen(date) {
  const uk = date.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
  let line = `${uk} UK`;
  try {
    const localTz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (localTz && localTz !== "Europe/London") {
      const local = date.toLocaleString("en-GB", {
        weekday: "short",
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      });
      line += ` · ${local} your time`;
    }
  } catch {
    /* ignore */
  }
  return line;
}

async function loadNextClubAuction() {
  const nowMs = Date.now();
  const [stateRes, plannedRes] = await Promise.all([
    supabase.rpc("club_auction_get_state"),
    supabase
      .from("gpsl_planned_events")
      .select("title, starts_at")
      .eq("kind", "club_auction")
      .eq("visible", true)
      .gt("starts_at", new Date(nowMs).toISOString())
      .order("starts_at", { ascending: true })
      .limit(1),
  ]);

  const state = stateRes.data || null;
  const candidates = [];

  if (state?.enabled && state?.start_time) {
    const t = new Date(state.start_time).getTime();
    if (t > nowMs) candidates.push({ at: t, title: "Club draft auction", armed: true });
  }
  const planned = !plannedRes.error && plannedRes.data?.[0];
  if (planned?.starts_at) {
    candidates.push({
      at: new Date(planned.starts_at).getTime(),
      title: planned.title || "Club draft auction",
      armed: false,
    });
  }

  candidates.sort((a, b) => a.at - b.at);
  return {
    next: candidates[0] || null,
    biddingOpen: Boolean(state?.bidding_open),
  };
}

/**
 * @param {{ card: HTMLElement|null, countdownEl: HTMLElement|null, whenEl: HTMLElement|null,
 *           titleEl?: HTMLElement|null, suppressWhenVisible?: () => boolean }} opts
 */
export async function mountNextClubAuctionCountdown(opts) {
  const { card, countdownEl, whenEl, titleEl = null, suppressWhenVisible = () => false } = opts || {};
  if (!card || !countdownEl) return;

  let info = await loadNextClubAuction();
  let reloading = false;

  const paint = async () => {
    if (reloading) return;
    if (suppressWhenVisible()) {
      card.hidden = true;
      return;
    }
    if (info.biddingOpen && !info.next) {
      card.hidden = true;
      return;
    }
    if (!info.next) {
      card.hidden = true;
      return;
    }
    const remaining = info.next.at - Date.now();
    if (remaining <= 0) {
      reloading = true;
      try {
        info = await loadNextClubAuction();
      } finally {
        reloading = false;
      }
      return;
    }
    card.hidden = false;
    if (titleEl) titleEl.textContent = info.next.title;
    countdownEl.textContent = `Opens in ${formatRemaining(remaining)}`;
    if (whenEl) {
      whenEl.textContent =
        formatWhen(new Date(info.next.at)) + (info.next.armed ? "" : " · scheduled");
    }
  };

  await paint();
  setInterval(paint, 1000);
}
