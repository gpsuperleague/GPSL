/**
 * My Calendar — real-world month view for owners (V1).
 * Agreed KOs · Club Wire cutoffs · GPSL unlock/lock · availability wash.
 */
import { supabase, initGlobal, getAuthUserFast } from "./global.js";
import { GPSL_MONTH_LABELS, CUP_LABELS, DIVISION_LABELS } from "./competition.js";
import {
  loadSeasonCalendarMonths,
  formatUkDateTime,
} from "./competition_calendar.js";
import { loadAvailabilityContext, UK_TZ } from "./match_scheduling.js";

const UK = UK_TZ || "Europe/London";
const DOW_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

let viewYear;
let viewMonth; // 1–12
let ownerTz = UK;
let weeklySlots = [];
let fixtures = [];
let cutoffs = [];
let seasonMonths = [];
let selectedYmd = null;
let myClub = { short: null, name: null };

function pad2(n) {
  return String(n).padStart(2, "0");
}

function ymd(year, month, day) {
  return `${year}-${pad2(month)}-${pad2(day)}`;
}

function escapeHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function showError(msg) {
  const el = document.getElementById("ocError");
  if (!el) return;
  if (!msg) {
    el.style.display = "none";
    el.textContent = "";
    return;
  }
  el.style.display = "block";
  el.textContent = msg;
}

/** Civil YYYY-MM-DD for an Instant in a timezone. */
function ymdInTz(isoOrDate, timeZone) {
  const d = isoOrDate instanceof Date ? isoOrDate : new Date(isoOrDate);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(d);
  const get = (t) => parts.find((p) => p.type === t)?.value;
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/** ISO weekday 1=Mon … 7=Sun for a civil ymd (noon UTC probe). */
function isoDowForYmd(ymdStr, timeZone) {
  const probe = new Date(`${ymdStr}T12:00:00Z`);
  const wd = new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
  }).format(probe);
  const map = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  return map[wd] || 1;
}

function todayYmd(timeZone) {
  return ymdInTz(new Date(), timeZone);
}

function monthLabel(year, month) {
  return new Date(Date.UTC(year, month - 1, 1)).toLocaleString("en-GB", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
}

function timeInTz(iso, timeZone) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    timeZone,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/** HH:MM in owner TZ for compact chips. */
function hhmmInTz(iso, timeZone) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function truncateChip(text, max = 14) {
  const s = String(text || "").trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max - 1)}…`;
}

function fixtureChipText(f) {
  const home = (f.home_club_short_name || "?").toUpperCase();
  const away = (f.away_club_short_name || "?").toUpperCase();
  const me = (myClub.short || "").toUpperCase();
  if (me && home === me) return `vs ${away}`;
  if (me && away === me) return `@ ${home}`;
  return `${home}-${away}`;
}

function deadlineChipText(c) {
  const t = String(c.title || c.kind || "Deadline");
  if (/reply/i.test(t)) return "Reply";
  if (/propose/i.test(t)) return "Propose";
  if (/check.?in/i.test(t)) return "Check-in";
  if (/video/i.test(t)) return "Video";
  if (/month.?lock/i.test(t)) return "Month lock";
  if (/late/i.test(t)) return "Late fee";
  return truncateChip(t, 12);
}

function formatSlotRange(slotsForDow) {
  if (!slotsForDow.length) return "";
  const sorted = [...slotsForDow].sort(
    (a, b) => a.hour * 60 + a.minute - (b.hour * 60 + b.minute)
  );
  const ranges = [];
  let start = sorted[0];
  let prev = sorted[0];
  const toLabel = (s) => `${pad2(s.hour)}:${pad2(s.minute)}`;
  for (let i = 1; i < sorted.length; i++) {
    const cur = sorted[i];
    const prevEnd = prev.hour * 60 + prev.minute + 30;
    const curStart = cur.hour * 60 + cur.minute;
    if (curStart === prevEnd) {
      prev = cur;
      continue;
    }
    ranges.push(`${toLabel(start)}–${toLabel({ hour: Math.floor(prevEnd / 60), minute: prevEnd % 60 })}`);
    start = cur;
    prev = cur;
  }
  const endMins = prev.hour * 60 + prev.minute + 30;
  ranges.push(
    `${toLabel(start)}–${toLabel({ hour: Math.floor(endMins / 60), minute: endMins % 60 })}`
  );
  return ranges.join(", ");
}

function fixtureTitle(f) {
  const home = f.home_club_short_name || "?";
  const away = f.away_club_short_name || "?";
  if (f.competition_type === "cup") {
    const cup = CUP_LABELS[f.cup_code] || f.cup_code || "Cup";
    return `${home} vs ${away} · ${cup}`;
  }
  const div = DIVISION_LABELS[f.division] || f.division || "League";
  const md = f.matchday != null ? ` MD${f.matchday}` : "";
  return `${home} vs ${away} · ${div}${md}`;
}

function fixtureHref(f) {
  if (f.status === "played") {
    return `matchday.html?fixture=${encodeURIComponent(String(f.id))}`;
  }
  if (f.schedule_status === "agreed" && f.agreed_kickoff_at) {
    return `matchday.html?fixture=${encodeURIComponent(String(f.id))}`;
  }
  return `fixture_schedule.html?fixture=${encodeURIComponent(String(f.id))}`;
}

/** Build event list keyed by owner-local ymd. */
function buildEventsByDay() {
  /** @type {Map<string, object[]>} */
  const map = new Map();
  const push = (day, ev) => {
    if (!day) return;
    if (!map.has(day)) map.set(day, []);
    map.get(day).push(ev);
  };

  for (const f of fixtures) {
    if (!f.agreed_kickoff_at) continue;
    const day = ymdInTz(f.agreed_kickoff_at, ownerTz);
    const hhmm = hhmmInTz(f.agreed_kickoff_at, ownerTz);
    push(day, {
      kind: "match",
      sort: new Date(f.agreed_kickoff_at).getTime(),
      title: fixtureTitle(f),
      detail: `${timeInTz(f.agreed_kickoff_at, ownerTz)} · ${
        f.status === "played" ? "Played" : "Agreed kick-off"
      }`,
      href: fixtureHref(f),
      hrefLabel: f.status === "played" ? "Match Day →" : "Match Day / schedule →",
      chip: `${hhmm} ${fixtureChipText(f)}`,
    });
  }

  for (const c of cutoffs) {
    if (!c?.at) continue;
    const day = ymdInTz(c.at, ownerTz);
    const hhmm = hhmmInTz(c.at, ownerTz);
    push(day, {
      kind: "deadline",
      sort: new Date(c.at).getTime(),
      title: c.title || "Deadline",
      detail: `${timeInTz(c.at, ownerTz)}${c.detail ? ` — ${c.detail}` : ""}`,
      href: c.href || "dashboard.html",
      hrefLabel: "Open →",
      chip: `${hhmm} ${deadlineChipText(c)}`,
    });
  }

  for (const m of seasonMonths) {
    const label =
      GPSL_MONTH_LABELS[m.gpsl_month] || m.gpsl_month_label || m.gpsl_month || "Month";
    if (m.unlock_at) {
      const day = ymdInTz(m.unlock_at, ownerTz);
      const hhmm = hhmmInTz(m.unlock_at, ownerTz);
      push(day, {
        kind: "gpsl",
        sort: new Date(m.unlock_at).getTime(),
        title: `GPSL ${label} unlocks`,
        detail: `${timeInTz(m.unlock_at, ownerTz)} · play month opens (UK lock cycle: ${formatUkDateTime(m.unlock_at)} UK)`,
        href: "season_calendar.html",
        hrefLabel: "Season Calendar →",
        chip: `${hhmm} Unlock`,
      });
    }
    if (m.lock_at) {
      const day = ymdInTz(m.lock_at, ownerTz);
      const hhmm = hhmmInTz(m.lock_at, ownerTz);
      push(day, {
        kind: "gpsl",
        sort: new Date(m.lock_at).getTime(),
        title: `GPSL ${label} locks`,
        detail: `${timeInTz(m.lock_at, ownerTz)} · month end / fines window (${formatUkDateTime(m.lock_at)} UK)`,
        href: "fixtures.html",
        hrefLabel: "Fixtures →",
        chip: `${hhmm} Lock`,
      });
    }
  }

  for (const [, list] of map) {
    list.sort((a, b) => a.sort - b.sort);
  }
  return map;
}

function availIsoDows() {
  const set = new Set();
  for (const s of weeklySlots) {
    const dow = Number(s.iso_dow);
    if (dow >= 1 && dow <= 7) set.add(dow);
  }
  return set;
}

function slotsForIsoDow(isoDow) {
  return weeklySlots.filter((s) => Number(s.iso_dow) === isoDow);
}

function gridCells(year, month) {
  const firstDow = isoDowForYmd(ymd(year, month, 1), ownerTz); // 1=Mon
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const prevYear = month === 1 ? year - 1 : year;
  const prevMonth = month === 1 ? 12 : month - 1;
  const prevDays = new Date(Date.UTC(prevYear, prevMonth, 0)).getUTCDate();
  const nextYear = month === 12 ? year + 1 : year;
  const nextMonth = month === 12 ? 1 : month + 1;

  const cells = [];
  for (let i = firstDow - 1; i > 0; i--) {
    const day = prevDays - i + 1;
    cells.push({ ymd: ymd(prevYear, prevMonth, day), day, outside: true });
  }
  for (let d = 1; d <= daysInMonth; d++) {
    cells.push({ ymd: ymd(year, month, d), day: d, outside: false });
  }
  let nextDay = 1;
  while (cells.length % 7 !== 0) {
    cells.push({
      ymd: ymd(nextYear, nextMonth, nextDay),
      day: nextDay,
      outside: true,
    });
    nextDay += 1;
  }
  return cells;
}

function renderGrid() {
  const grid = document.getElementById("ocGrid");
  const title = document.getElementById("ocMonthTitle");
  if (title) title.textContent = monthLabel(viewYear, viewMonth);
  if (!grid) return;

  const eventsByDay = buildEventsByDay();
  const availDows = availIsoDows();
  const today = todayYmd(ownerTz);
  const cells = gridCells(viewYear, viewMonth);

  grid.innerHTML = cells
    .map((c) => {
      const events = eventsByDay.get(c.ymd) || [];
      const dow = isoDowForYmd(c.ymd, ownerTz);
      const hasAvail = availDows.has(dow);
      const shown = events.slice(0, 2);
      const more = events.length - shown.length;
      const chipHtml = shown
        .map(
          (ev) =>
            `<span class="oc-chip oc-chip--${escapeHtml(ev.kind)}" title="${escapeHtml(
              ev.title
            )}">${escapeHtml(ev.chip || ev.title)}</span>`
        )
        .join("");
      const extra =
        more > 0
          ? `<span class="oc-more">+${more} more</span>`
          : "";
      const cls = [
        "oc-day",
        c.outside ? "is-outside" : "",
        c.ymd === today ? "is-today" : "",
        c.ymd === selectedYmd ? "is-selected" : "",
        hasAvail ? "has-avail" : "",
      ]
        .filter(Boolean)
        .join(" ");
      return `
        <button type="button" class="${cls}" data-ymd="${c.ymd}" aria-label="${c.ymd}">
          <div class="oc-day-num">${c.day}</div>
          <div class="oc-chips">${chipHtml}${extra}</div>
        </button>`;
    })
    .join("");

  grid.querySelectorAll(".oc-day").forEach((btn) => {
    btn.addEventListener("click", () => {
      selectedYmd = btn.getAttribute("data-ymd");
      renderGrid();
      renderPanel();
    });
  });
}

function renderPanel() {
  const title = document.getElementById("ocPanelTitle");
  const sub = document.getElementById("ocPanelSub");
  const body = document.getElementById("ocPanelBody");
  if (!body) return;

  if (!selectedYmd) {
    if (title) title.textContent = "Select a day";
    if (sub)
      sub.textContent = "Click a day for matches, deadlines, and availability.";
    body.innerHTML = `<p class="oc-empty">No day selected.</p>`;
    return;
  }

  const [y, m, d] = selectedYmd.split("-").map(Number);
  const dow = isoDowForYmd(selectedYmd, ownerTz);
  const dowName = DOW_SHORT[dow - 1] || "";
  if (title) title.textContent = `${dowName} ${d} ${monthLabel(y, m).split(" ")[0]}`;
  if (sub) sub.textContent = selectedYmd === todayYmd(ownerTz) ? "Today" : selectedYmd;

  const eventsByDay = buildEventsByDay();
  const events = eventsByDay.get(selectedYmd) || [];
  const daySlots = slotsForIsoDow(dow);
  const availLine = daySlots.length
    ? formatSlotRange(daySlots)
    : null;

  const parts = [];
  if (availLine) {
    parts.push(`
      <div class="oc-event">
        <span class="oc-event-kind oc-event-kind--avail">AVAILABILITY</span>
        <b>Usually free</b>
        <div class="detail">${escapeHtml(availLine)} (${escapeHtml(ownerTz)})</div>
        <a href="owner_details.html">Edit on Owner Details →</a>
      </div>`);
  } else {
    parts.push(`
      <div class="oc-event">
        <span class="oc-event-kind oc-event-kind--avail">AVAILABILITY</span>
        <b>No weekly slots this weekday</b>
        <div class="detail">Set availability so opponents can propose overlapping times.</div>
        <a href="owner_details.html">Set availability →</a>
      </div>`);
  }

  if (!events.length) {
    parts.push(`<p class="oc-empty">No matches, deadlines, or GPSL locks on this day.</p>`);
  } else {
    for (const ev of events) {
      parts.push(`
        <div class="oc-event">
          <span class="oc-event-kind oc-event-kind--${escapeHtml(ev.kind)}">${escapeHtml(
            ev.kind === "match"
              ? "MATCH"
              : ev.kind === "deadline"
                ? "DEADLINE"
                : "GPSL"
          )}</span>
          <b>${escapeHtml(ev.title)}</b>
          <div class="detail">${escapeHtml(ev.detail)}</div>
          ${
            ev.href
              ? `<a href="${escapeHtml(ev.href)}">${escapeHtml(ev.hrefLabel || "Open →")}</a>`
              : ""
          }
        </div>`);
    }
  }

  body.innerHTML = parts.join("");
}

async function loadMyClub(user) {
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClub = { short: club?.ShortName || null, name: club?.Club || null };
}

async function loadMyFixtures() {
  if (!myClub.short) return [];
  const key = myClub.short.trim().toUpperCase();
  const { data, error } = await supabase
    .from("competition_fixtures_public")
    .select(
      "id, home_club_short_name, away_club_short_name, competition_type, cup_code, division, matchday, status, schedule_status, agreed_kickoff_at, gpsl_month"
    );
  if (error) {
    console.warn("owner_calendar fixtures:", error);
    return [];
  }
  return (data || []).filter(
    (f) =>
      f.agreed_kickoff_at &&
      ((f.home_club_short_name || "").trim().toUpperCase() === key ||
        (f.away_club_short_name || "").trim().toUpperCase() === key)
  );
}

async function loadCutoffs() {
  const { data, error } = await supabase.rpc("club_wire_cutoffs");
  if (error) {
    console.warn("club_wire_cutoffs:", error);
    return [];
  }
  return Array.isArray(data?.cutoffs) ? data.cutoffs : [];
}

function shiftMonth(delta) {
  let m = viewMonth + delta;
  let y = viewYear;
  if (m < 1) {
    m = 12;
    y -= 1;
  } else if (m > 12) {
    m = 1;
    y += 1;
  }
  viewYear = y;
  viewMonth = m;
  selectedYmd = null;
  renderGrid();
  renderPanel();
}

function goToday() {
  const t = todayYmd(ownerTz);
  const [y, m] = t.split("-").map(Number);
  viewYear = y;
  viewMonth = m;
  selectedYmd = t;
  renderGrid();
  renderPanel();
}

async function boot() {
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    showError("Sign in to view your calendar.");
    return;
  }

  await loadMyClub(user);
  if (!myClub.short) {
    showError("No club linked to this account — My Calendar needs a club.");
    return;
  }

  const now = new Date();
  const today = todayYmd(UK);
  const [ty, tm] = (today || ymdInTz(now, UK) || "").split("-").map(Number);
  viewYear = ty || now.getFullYear();
  viewMonth = tm || now.getMonth() + 1;
  selectedYmd = todayYmd(UK);

  document.getElementById("ocPrev")?.addEventListener("click", () => shiftMonth(-1));
  document.getElementById("ocNext")?.addEventListener("click", () => shiftMonth(1));
  document.getElementById("ocToday")?.addEventListener("click", goToday);

  try {
    const [avail, months, fix, cuts] = await Promise.all([
      loadAvailabilityContext().catch((e) => {
        console.warn(e);
        return null;
      }),
      loadSeasonCalendarMonths(supabase),
      loadMyFixtures(),
      loadCutoffs(),
    ]);

    ownerTz = avail?.timezone || UK;
    weeklySlots = Array.isArray(avail?.weekly_slots) ? avail.weekly_slots : [];
    seasonMonths = months || [];
    fixtures = fix || [];
    cutoffs = cuts || [];

    selectedYmd = todayYmd(ownerTz);
    const [y, m] = selectedYmd.split("-").map(Number);
    viewYear = y;
    viewMonth = m;

    const tzEl = document.getElementById("ocTzLabel");
    if (tzEl) {
      tzEl.textContent = `Times in ${ownerTz}${
        myClub.name || myClub.short
          ? ` · ${myClub.name || myClub.short}`
          : ""
      }`;
    }

    renderGrid();
    renderPanel();
  } catch (e) {
    console.error(e);
    showError(e.message || "Could not load calendar.");
  }
}

boot();
