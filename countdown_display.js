// Shared countdown labels: duration + UK wall time + viewer local time

export function isValidInstant(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

const UK_TZ = "Europe/London";

const ukDateTimeFmt = new Intl.DateTimeFormat("en-GB", {
  timeZone: UK_TZ,
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

const ukDateTimePreciseFmt = new Intl.DateTimeFormat("en-GB", {
  timeZone: UK_TZ,
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

const localDateTimeFmt = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
});

const localDateTimePreciseFmt = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

export function formatDurationMs(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export function formatInstantUK(instant, options = {}) {
  if (!isValidInstant(instant)) return "";
  const fmt = options.precise ? ukDateTimePreciseFmt : ukDateTimeFmt;
  return `${fmt.format(instant)} UK`;
}

export function formatInstantLocal(instant, options = {}) {
  if (!isValidInstant(instant)) return "";
  const fmt = options.precise ? localDateTimePreciseFmt : localDateTimeFmt;
  return `${fmt.format(instant)} (your time)`;
}

const PRECISE = { precise: true };

/** Plain text: UK line, then local line (for textContent / two-line labels). */
export function formatTargetTimesSubline(targetInstant) {
  if (!isValidInstant(targetInstant)) return "";
  return `${formatInstantUK(targetInstant)}\n${formatInstantLocal(targetInstant)}`;
}

/** Random window / count-up: when the phase started (UK + viewer local). */
export function formatStartedTimesSubline(startInstant) {
  if (!isValidInstant(startInstant)) return "";
  return `Started ${formatInstantUK(startInstant)}\n${formatInstantLocal(startInstant)}`;
}

/** After secret random finish: when bidding closed (UK + viewer local, with seconds). */
export function formatClosedTimesSubline(closedInstant) {
  if (!isValidInstant(closedInstant)) return "";
  return (
    `Bidding closed ${formatInstantUK(closedInstant, PRECISE)}\n` +
    `${formatInstantLocal(closedInstant, PRECISE)}`
  );
}

export function draftAuctionKindLabel(kind = "player") {
  if (kind === "manager") return "Manager draft";
  if (kind === "club") return "Club auction";
  return "Player draft";
}

/** Conclusion banner once the draft window has fully ended. */
export function formatDraftConclusionLines(finishInstant, kind = "player") {
  if (!isValidInstant(finishInstant)) {
    return { duration: "", subline: "" };
  }
  const noun = draftAuctionKindLabel(kind);
  return {
    duration: `${noun} concluded — random finish ${formatInstantUK(finishInstant, PRECISE)}`,
    subline: formatClosedTimesSubline(finishInstant),
  };
}

/** Prefix live countdown line so player vs manager draft is obvious on shared pages. */
export function prefixDraftCountdownDuration(duration, kind = "player") {
  const text = String(duration || "").trim();
  if (!text) return text;
  const noun = draftAuctionKindLabel(kind);
  if (text.startsWith(noun)) return text;
  return `${noun}: ${text}`;
}

/** HTML: UK and local each on their own line inside .countdown-times */
export function formatTargetTimesHtml(targetInstant) {
  if (!isValidInstant(targetInstant)) return "";
  return (
    `<span class="countdown-uk">${escapeHtml(formatInstantUK(targetInstant))}</span>` +
    `<span class="countdown-local">${escapeHtml(formatInstantLocal(targetInstant))}</span>`
  );
}

export function getCountdownParts(targetInstant) {
  const end =
    targetInstant instanceof Date ? targetInstant : new Date(targetInstant);
  if (!isValidInstant(end)) {
    return { duration: "", subline: "", expired: true };
  }

  const ms = end.getTime() - Date.now();
  if (ms <= 0) {
    return {
      duration: "Expired",
      subline: formatTargetTimesSubline(end),
      expired: true,
    };
  }

  return {
    duration: formatDurationMs(ms),
    subline: formatTargetTimesSubline(end),
    expired: false,
  };
}

export function formatTimeRemainingPlain(endTime) {
  const { duration, subline, expired } = getCountdownParts(new Date(endTime));
  if (expired) return duration;
  return subline ? `${duration}\n${subline}` : duration;
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function formatTimeRemainingHtml(endTime) {
  const end = new Date(endTime);
  const { duration, expired } = getCountdownParts(end);
  if (!duration) return "";

  const timesHtml = isValidInstant(end) ? formatTargetTimesHtml(end) : "";
  const timesBlock = timesHtml
    ? `<br><span class="countdown-times">${timesHtml}</span>`
    : "";

  if (expired) {
    return `<span class="countdown-duration">${escapeHtml(duration)}</span>${timesBlock}`;
  }

  return `<span class="countdown-duration">${escapeHtml(duration)}</span>${timesBlock}`;
}

/** Two-line timer text for a single DOM node (duration + UK/local). */
export function formatLiveCountdownLines(label, ms, targetInstant, options = {}) {
  const countUp = options.countUp === true;
  const frozen = options.frozen === true;
  const finishInstant = options.finishInstant;
  let headline = label;
  if (frozen && isValidInstant(finishInstant)) {
    headline = `${label} — random finish ${formatInstantUK(finishInstant, PRECISE)}`;
  }
  const duration =
    countUp || ms > 0 ? `${headline}: ${formatDurationMs(ms)}` : headline;
  let subline = "";
  if (frozen && isValidInstant(finishInstant)) {
    subline = formatClosedTimesSubline(finishInstant);
  } else if (!frozen && isValidInstant(targetInstant)) {
    subline = countUp
      ? formatStartedTimesSubline(targetInstant)
      : formatTargetTimesSubline(targetInstant);
  }
  return { duration, subline };
}
