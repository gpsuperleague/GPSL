// Shared draft phase timeline — never uses draft_random_finish_time (DB secret only)

export function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

function parseFinishInstant(raw) {
  if (raw instanceof Date) return isValidDate(raw) ? raw : null;
  if (raw) {
    const d = new Date(raw);
    return isValidDate(d) ? d : null;
  }
  return null;
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

/** Clock phase + server bid gate (draft_bidding_open from global_settings_public). */
export function getEffectiveDraftPhase(nowUK, draftAuctionStartTime, options = {}) {
  const phase = getDraftPhaseFromStart(nowUK, draftAuctionStartTime);
  if (options.biddingOpen === false) {
    if (phase === "before_start" || phase === "live_until_cutoff") return phase;
    if (phase === "pre_random" || phase === "random_active") return "random_locked";
    return "ended";
  }
  return phase;
}

export function isDraftAuctionEnded(nowUK, draftAuctionStartTime, options = {}) {
  const phase = getEffectiveDraftPhase(nowUK, draftAuctionStartTime, options);
  return phase === "ended" || phase === "random_locked";
}

/** Shared countdown tick for dashboard / GPDB / draft auction pages. */
export function getDraftCountdownTick(nowUK, draftAuctionStartTime, options = {}) {
  const timeline = getDraftTimelineFromStart(
    isValidDate(draftAuctionStartTime)
      ? new Date(draftAuctionStartTime)
      : null
  );
  const phase = getEffectiveDraftPhase(
    nowUK,
    draftAuctionStartTime,
    options
  );

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
        label: "Random window (bidding open)",
        target: timeline.randomStart,
        countUp: true,
      };
    case "random_locked": {
      const finishInstant = parseFinishInstant(options.finishInstant);
      const finishMs = finishInstant ? finishInstant.getTime() : null;
      const elapsed =
        options.frozenMs != null
          ? options.frozenMs
          : finishMs != null && Number.isFinite(finishMs)
            ? Math.max(0, finishMs - timeline.randomStart.getTime())
            : 0;
      return {
        phase,
        ms: elapsed,
        label: "Bidding locked — draft settles after 7pm auctions",
        target: timeline.randomStart,
        countUp: true,
        frozen: Boolean(finishInstant),
        finishInstant,
      };
    }
    case "ended": {
      const finishInstant = parseFinishInstant(options.finishInstant);
      return {
        phase,
        ms: 0,
        label: finishInstant ? "Draft auction concluded" : "Draft has ended",
        target: null,
        countUp: false,
        concluded: Boolean(finishInstant),
        finishInstant,
      };
    }
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
      return "Random window — bidding closes at a random second between 6:50 and 6:59pm UK";
    case "random_locked":
      return "Bidding locked — players & money settle after tonight's 7pm transfer auctions";
    case "ended":
      return "Draft auction ended";
    default:
      return "";
  }
}

// ---------------------------------------------------------------------------
// Manager draft — no 6pm cutoff; live bidding until 6:50pm random window
// ---------------------------------------------------------------------------

export function getManagerDraftPhaseFromStart(nowUK, draftAuctionStartTime) {
  const t = getDraftTimelineFromStart(draftAuctionStartTime);
  if (!t) return "ended";

  if (nowUK < t.start) return "before_start";
  if (nowUK < t.randomStart) return "live";
  if (nowUK < t.publicEnd) return "random_active";
  return "ended";
}

export function getManagerDraftEffectivePhase(nowUK, draftAuctionStartTime, options = {}) {
  const phase = getManagerDraftPhaseFromStart(nowUK, draftAuctionStartTime);
  if (options.biddingOpen === false) {
    if (phase === "before_start" || phase === "live") return phase;
    if (phase === "random_active") return "random_locked";
    return "ended";
  }
  return phase;
}

export function isManagerDraftAuctionEnded(nowUK, draftAuctionStartTime, options = {}) {
  const phase = getManagerDraftEffectivePhase(nowUK, draftAuctionStartTime, options);
  return phase === "ended" || phase === "random_locked";
}

/** MGDB “Open” on free agents while manager draft bidding is open (incl. secret random window). */
export function isManagerGpdbFreeAgentOfferAllowed(
  nowUK,
  draftAuctionStartTime,
  options = {}
) {
  const phase = getManagerDraftEffectivePhase(
    nowUK,
    draftAuctionStartTime,
    options
  );
  return phase === "live" || phase === "random_active";
}

export function getManagerDraftCountdownTick(nowUK, draftAuctionStartTime, options = {}) {
  const timeline = getDraftTimelineFromStart(
    isValidDate(draftAuctionStartTime) ? new Date(draftAuctionStartTime) : null
  );
  const phase = getManagerDraftEffectivePhase(nowUK, draftAuctionStartTime, options);

  if (!timeline) {
    return { phase, ms: 0, label: "Manager draft disabled", target: null, countUp: false };
  }

  switch (phase) {
    case "before_start":
      return {
        phase,
        ms: Math.max(0, timeline.start.getTime() - nowUK.getTime()),
        label: "Manager draft starts in",
        target: timeline.start,
        countUp: false,
      };
    case "live":
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
        label: "Random window (bidding open)",
        target: timeline.randomStart,
        countUp: true,
      };
    case "random_locked": {
      const finishInstant = parseFinishInstant(options.finishInstant);
      const finishMs = finishInstant ? finishInstant.getTime() : null;
      const elapsed =
        options.frozenMs != null
          ? options.frozenMs
          : finishMs != null && Number.isFinite(finishMs)
            ? Math.max(0, finishMs - timeline.randomStart.getTime())
            : 0;
      return {
        phase,
        ms: elapsed,
        label: "Bidding locked — manager draft settles after 7pm auctions",
        target: timeline.randomStart,
        countUp: true,
        frozen: Boolean(finishInstant),
        finishInstant,
      };
    }
    case "ended": {
      const finishInstant = parseFinishInstant(options.finishInstant);
      return {
        phase,
        ms: 0,
        label: finishInstant ? "Manager draft concluded" : "Manager draft has ended",
        target: null,
        countUp: false,
        concluded: Boolean(finishInstant),
        finishInstant,
      };
    }
    default:
      return { phase, ms: 0, label: "Manager draft disabled", target: null, countUp: false };
  }
}

export function managerDraftPhaseLabel(phase) {
  switch (phase) {
    case "before_start":
      return "Manager draft opens at 7pm UK (Day 1)";
    case "live":
      return "Live bidding — random window at 6:50pm UK (Day 2)";
    case "random_active":
      return "Random window — bidding closes at a random second between 6:50 and 6:59pm UK";
    case "random_locked":
      return "Bidding locked — manager contracts settle automatically when the transfer engine runs";
    case "ended":
      return "Manager draft auction ended";
    default:
      return "";
  }
}

// ---------------------------------------------------------------------------
// Club auction — same timeline as manager draft (no 6pm GPDB cutoff)
// Day 1 7pm UK → Day 2 6:50 random window → 6:59:59 latest
// ---------------------------------------------------------------------------

export const getClubAuctionPhaseFromStart = getManagerDraftPhaseFromStart;
export const getClubAuctionEffectivePhase = getManagerDraftEffectivePhase;
export const isClubAuctionEnded = isManagerDraftAuctionEnded;

export function getClubAuctionCountdownTick(nowUK, draftAuctionStartTime, options = {}) {
  const timeline = getDraftTimelineFromStart(
    isValidDate(draftAuctionStartTime) ? new Date(draftAuctionStartTime) : null
  );
  const phase = getClubAuctionEffectivePhase(nowUK, draftAuctionStartTime, options);

  if (!timeline) {
    return { phase, ms: 0, label: "Club auction disabled", target: null, countUp: false };
  }

  switch (phase) {
    case "before_start":
      return {
        phase,
        ms: Math.max(0, timeline.start.getTime() - nowUK.getTime()),
        label: "Club auction starts in",
        target: timeline.start,
        countUp: false,
      };
    case "live":
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
        label: "Random window (bidding open)",
        target: timeline.randomStart,
        countUp: true,
      };
    case "random_locked": {
      const finishInstant = parseFinishInstant(options.finishInstant);
      const finishMs = finishInstant ? finishInstant.getTime() : null;
      const elapsed =
        options.frozenMs != null
          ? options.frozenMs
          : finishMs != null && Number.isFinite(finishMs)
            ? Math.max(0, finishMs - timeline.randomStart.getTime())
            : 0;
      return {
        phase,
        ms: elapsed,
        label: "Bidding locked — club auction settles when the transfer engine runs",
        target: timeline.randomStart,
        countUp: true,
        frozen: Boolean(finishInstant),
        finishInstant,
      };
    }
    case "ended": {
      const finishInstant = parseFinishInstant(options.finishInstant);
      return {
        phase,
        ms: 0,
        label: finishInstant ? "Club auction concluded" : "Club auction has ended",
        target: null,
        countUp: false,
        concluded: Boolean(finishInstant),
        finishInstant,
      };
    }
    default:
      return { phase, ms: 0, label: "Club auction disabled", target: null, countUp: false };
  }
}

export function clubAuctionPhaseLabel(phase) {
  switch (phase) {
    case "before_start":
      return "Club auction opens at 7pm UK (Day 1)";
    case "live":
      return "Live bidding — random window at 6:50pm UK (Day 2)";
    case "random_active":
      return "Random window — bidding closes at a random second between 6:50 and 6:59:59pm UK";
    case "random_locked":
      return "Bidding locked — winning bids assign clubs when the transfer engine runs";
    case "ended":
      return "Club auction ended";
    default:
      return "";
  }
}
