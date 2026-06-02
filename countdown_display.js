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
  hour12: true,
});

const localDateTimeFmt = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
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

export function formatInstantUK(instant) {
  if (!isValidInstant(instant)) return "";
  return `${ukDateTimeFmt.format(instant)} UK`;
}

export function formatInstantLocal(instant) {
  if (!isValidInstant(instant)) return "";
  return `${localDateTimeFmt.format(instant)} (your time)`;
}

/** e.g. "Tue 3 Jun, 6:00 pm UK · Tue 3 Jun, 1:00 pm (your time)" */
export function formatTargetTimesSubline(targetInstant) {
  if (!isValidInstant(targetInstant)) return "";
  return `${formatInstantUK(targetInstant)} · ${formatInstantLocal(targetInstant)}`;
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
  const { duration, subline, expired } = getCountdownParts(new Date(endTime));
  if (!duration) return "";
  if (expired) {
    return `<span class="countdown-duration">${escapeHtml(duration)}</span>`;
  }
  const times = subline
    ? `<br><span class="countdown-times">${escapeHtml(subline)}</span>`
    : "";
  return `<span class="countdown-duration">${escapeHtml(duration)}</span>${times}`;
}

/** Two-line timer text for a single DOM node (duration + UK/local). */
export function formatLiveCountdownLines(label, ms, targetInstant) {
  const duration =
    ms > 0 ? `${label}: ${formatDurationMs(ms)}` : label;
  const subline =
    ms > 0 && isValidInstant(targetInstant)
      ? formatTargetTimesSubline(targetInstant)
      : isValidInstant(targetInstant)
        ? formatTargetTimesSubline(targetInstant)
        : "";
  return { duration, subline };
}
