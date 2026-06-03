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
      return "Random window active — exact end time is hidden";
    case "ended":
      return "Draft auction ended";
    default:
      return "";
  }
}
