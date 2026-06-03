// Shared draft phase timeline — never uses draft_random_finish_time (DB secret only)

export function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

/** Day 1 19:00 → Day 2 18:00 cutoff → 18:50 random window → latest 18:59:59 */
export function getDraftTimelineFromStart(draftAuctionStartTime) {
  if (!isValidDate(draftAuctionStartTime)) return null;

  const start = new Date(draftAuctionStartTime);
  const cutoff = new Date(start.getTime() + 23 * 60 * 60 * 1000);
  const randomStart = new Date(cutoff.getTime() + 50 * 60 * 1000);
  const publicEnd = new Date(
    start.getTime() + 23 * 60 * 60 * 1000 + 59 * 60 * 1000 + 59 * 1000
  );

  return { start, cutoff, randomStart, publicEnd };
}

export function getDraftPhaseFromStart(nowUK, draftAuctionStartTime) {
  const t = getDraftTimelineFromStart(draftAuctionStartTime);
  if (!t) return "ended";

  if (nowUK < t.start) return "before_start";
  if (nowUK < t.cutoff) return "live_until_cutoff";
  if (nowUK < t.randomStart) return "pre_random";
  if (nowUK < t.publicEnd) return "random_active";
  return "ended";
}

export function isDraftAuctionEnded(nowUK, draftAuctionStartTime) {
  return getDraftPhaseFromStart(nowUK, draftAuctionStartTime) === "ended";
}

/** Shared countdown tick for dashboard / GPDB / draft auction pages. */
export function getDraftCountdownTick(nowUK, draftAuctionStartTime) {
  const timeline = getDraftTimelineFromStart(
    isValidDate(draftAuctionStartTime)
      ? new Date(draftAuctionStartTime)
      : null
  );
  const phase = getDraftPhaseFromStart(nowUK, draftAuctionStartTime);

  if (!timeline) {
    return { phase, ms: 0, label: "Draft disabled", target: null, countUp: false };
  }

  switch (phase) {
    case "before_start":
      return {
        phase,
        ms: Math.max(0, timeline.start.getTime() - nowUK.getTime()),
        label: "Draft starts in",
        target: timeline.start,
        countUp: false,
      };
    case "live_until_cutoff":
      return {
        phase,
        ms: Math.max(0, timeline.cutoff.getTime() - nowUK.getTime()),
        label: "Auction cutoff in",
        target: timeline.cutoff,
        countUp: false,
      };
    case "pre_random":
      return {
        phase,
        ms: Math.max(0, timeline.randomStart.getTime() - nowUK.getTime()),
        label: "Random window begins in",
        target: timeline.randomStart,
        countUp: false,
      };
    case "random_active":
      return {
        phase,
        ms: Math.max(0, nowUK.getTime() - timeline.randomStart.getTime()),
        label: "Random window elapsed",
        target: timeline.randomStart,
        countUp: true,
      };
    case "ended":
      return { phase, ms: 0, label: "Draft has ended", target: null, countUp: false };
    default:
      return { phase, ms: 0, label: "Draft disabled", target: null, countUp: false };
  }
}

/** GPDB “Draft Offer” only during Day-1 7pm → Day-2 6pm UK live window. */
export function isGpdbFreeAgentOfferAllowed(nowUK, draftAuctionStartTime) {
  return (
    getDraftPhaseFromStart(nowUK, draftAuctionStartTime) === "live_until_cutoff"
  );
}

export function gpdbFreeAgentLockMessage(phase) {
  switch (phase) {
    case "before_start":
      return "Draft Closed";
    case "live_until_cutoff":
      return "";
    case "pre_random":
    case "random_active":
    case "ended":
      return "Draft Locked (6pm cutoff)";
    default:
      return "Draft Closed";
  }
}

export function draftPhaseLabel(phase) {
  switch (phase) {
    case "before_start":
      return "Draft opens at 7pm UK (Day 1)";
    case "live_until_cutoff":
      return "Live until 6pm UK cutoff (Day 2)";
    case "pre_random":
      return "Cutoff passed — random window opens at 6:50pm UK";
    case "random_active":
      return "Random window active — timer counts up from 6:50pm UK";
    case "ended":
      return "Draft auction ended";
    default:
      return "";
  }
}
