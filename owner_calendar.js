/**
 * My Calendar — real-world month view for owners (V1).
 * Agreed KOs · Club Wire cutoffs · GPSL unlock/lock · availability wash ·
 * special/planned auctions · transfer window guide + live status ·
 * match video upload deadlines (+24h extension only after miss).
 */
import { supabase, initGlobal, getAuthUserFast } from "./global.js";
import { GPSL_MONTH_LABELS, CUP_LABELS, DIVISION_LABELS } from "./competition.js";
import {
  loadSeasonCalendarMonths,
  formatUkDateTime,
} from "./competition_calendar.js";
import { loadAvailabilityContext, UK_TZ } from "./match_scheduling.js";
import {
  loadClubsMap,
  fullClubName,
  ownerTagForClub,
} from "./clubs_lookup.js";
import { loadUpcomingSpecialAuctions } from "./special_auction_upcoming.js";

const UK = UK_TZ || "Europe/London";
const DOW_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

const AUCTION_TYPE_LABELS = {
  snap: "Snap auction",
  blind_gauntlet: "Blind Gauntlet",
  lowest_unique: "Lowest unique bid",
};

const PLANNED_AUCTION_KINDS = new Set([
  "player_draft",
  "manager_draft",
  "club_auction",
]);

const PLANNED_DEFAULT_LINK = {
  player_draft: { href: "draftauction.html", label: "Draft auction →" },
  manager_draft: { href: "manager_draftauction.html", label: "Manager draft →" },
  club_auction: { href: "club_auction.html", label: "Club auction →" },
};

const PLANNED_CHIP = {
  player_draft: "Draft",
  manager_draft: "Mgr draft",
  club_auction: "Club auc.",
};

let viewYear;
let viewMonth; // 1–12
let ownerTz = UK;
let weeklySlots = [];
let fixtures = [];
let cutoffs = [];
let seasonMonths = [];
let specialAuctions = [];
let plannedEvents = [];
/** @type {object|null} */
let marketSettings = null;
/** First video-due deadlines computed for played fixtures still missing a video. */
let videoDeadlines = [];
let videoGraceHours = 72;
let selectedYmd = null;
/** @type {string|null} event key to highlight/scroll in the day panel */
let focusEventKey = null;
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

function clubFull(short, fallbackName) {
  const s = String(short || "").trim();
  const fromMap = s ? fullClubName(s) : "";
  if (fromMap && fromMap !== s) return fromMap;
  return String(fallbackName || fromMap || s || "?").trim() || "?";
}

function oppShortForMe(f) {
  const me = (myClub.short || "").toUpperCase();
  const home = (f.home_club_short_name || "").trim().toUpperCase();
  const away = (f.away_club_short_name || "").trim().toUpperCase();
  if (me && home === me) return f.away_club_short_name;
  if (me && away === me) return f.home_club_short_name;
  return null;
}

function fixtureChipText(f) {
  const home = clubFull(f.home_club_short_name, f.home_club_name);
  const away = clubFull(f.away_club_short_name, f.away_club_name);
  const me = (myClub.short || "").toUpperCase();
  const homeKey = (f.home_club_short_name || "").trim().toUpperCase();
  const awayKey = (f.away_club_short_name || "").trim().toUpperCase();
  if (me && homeKey === me) return `vs ${away}`;
  if (me && awayKey === me) return `@ ${home}`;
  return `${home} vs ${away}`;
}

function fixtureOppOwnerLine(f) {
  const opp = oppShortForMe(f);
  if (!opp) return "";
  const owner = ownerTagForClub(opp);
  return owner ? `Owner: ${owner}` : "Owner: Vacant";
}

function fixtureChipHover(f) {
  const ownerBit = fixtureOppOwnerLine(f);
  const base = fixtureTitle(f);
  return ownerBit ? `${base} · ${ownerBit}` : base;
}

function deadlineChipText(c) {
  const kind = String(c.kind || "");
  if (kind === "video_suspend") return "Video +24h";
  if (kind === "video") return "Video due";
  const t = String(c.title || c.kind || "Deadline");
  if (/reply/i.test(t)) return "Reply";
  if (/propose/i.test(t)) return "Propose";
  if (/check.?in/i.test(t)) return "Check-in";
  if (/video/i.test(t)) return "Video due";
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
  const home = clubFull(f.home_club_short_name, f.home_club_name);
  const away = clubFull(f.away_club_short_name, f.away_club_name);
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

function specialAuctionHref(a) {
  return a?.auction_type === "blind_gauntlet"
    ? `special_auction_gauntlet.html?id=${a.id}`
    : `special_auction.html?id=${encodeURIComponent(String(a.id))}`;
}

function eventKindLabel(kind) {
  if (kind === "match") return "MATCH";
  if (kind === "deadline") return "DEADLINE";
  if (kind === "gpsl") return "GPSL";
  if (kind === "auction") return "AUCTION";
  if (kind === "transfer") return "TRANSFER";
  if (kind === "video") return "VIDEO";
  if (kind === "video_ext") return "VIDEO +24h";
  return String(kind || "EVENT").toUpperCase();
}

function pushVideoCutoffEvent(push, c, kind) {
  if (!c?.at) return;
  const day = ymdInTz(c.at, ownerTz);
  const hhmm = hhmmInTz(c.at, ownerTz);
  const sort = new Date(c.at).getTime();
  const isExt = kind === "video_ext";
  push(day, {
    key: `${kind}:${c.fixture_id || c.id || sort}`,
    kind,
    sort,
    title: c.title || (isExt ? "Video upload — 24h extension" : "Upload match video"),
    detail: `${timeInTz(c.at, ownerTz)}${c.detail ? ` — ${c.detail}` : ""}`,
    href: c.href || (c.fixture_id ? `matchday.html?fixture=${c.fixture_id}` : "dashboard.html"),
    hrefLabel: "Match Day →",
    chip: `${hhmm} ${isExt ? "Video +24h" : "Video due"}`,
    chipTitle: isExt
      ? "24h point-suspend window — upload to clear the suspended point"
      : "Match video upload deadline (month lock + grace)",
  });
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
  /** Dedupe auction-like starts that land on the same minute. */
  const seenAuctionStarts = new Set();
  const claimAuctionStart = (iso) => {
    const t = new Date(iso).getTime();
    if (!Number.isFinite(t)) return true;
    const bucket = Math.round(t / 60_000);
    if (seenAuctionStarts.has(bucket)) return false;
    seenAuctionStarts.add(bucket);
    return true;
  };

  for (const f of fixtures) {
    if (!f.agreed_kickoff_at) continue;
    const day = ymdInTz(f.agreed_kickoff_at, ownerTz);
    const hhmm = hhmmInTz(f.agreed_kickoff_at, ownerTz);
    push(day, {
      key: `match:${f.id}`,
      kind: "match",
      sort: new Date(f.agreed_kickoff_at).getTime(),
      title: fixtureTitle(f),
      detail: `${timeInTz(f.agreed_kickoff_at, ownerTz)} · ${
        f.status === "played" ? "Played" : "Agreed kick-off"
      }`,
      href: fixtureHref(f),
      hrefLabel: f.status === "played" ? "Match Day →" : "Match Day / schedule →",
      chip: `${hhmm} ${fixtureChipText(f)}`,
      chipTitle: fixtureChipHover(f),
      ownerLine: fixtureOppOwnerLine(f),
    });
  }

  /** Fixtures already in the 24h suspend window — extension only, not a second "due". */
  const videoExtFixtureIds = new Set();
  for (const c of cutoffs) {
    if (c?.kind === "video_suspend" && c.fixture_id != null) {
      videoExtFixtureIds.add(String(c.fixture_id));
    }
  }

  for (const c of cutoffs) {
    if (!c?.at) continue;
    if (c.kind === "video_suspend") {
      // Only visible after missing the first deadline (Club Wire sets pts_status=suspended).
      pushVideoCutoffEvent(push, c, "video_ext");
      continue;
    }
    if (c.kind === "video") {
      if (c.fixture_id != null && videoExtFixtureIds.has(String(c.fixture_id))) continue;
      pushVideoCutoffEvent(push, c, "video");
      continue;
    }
    const day = ymdInTz(c.at, ownerTz);
    const hhmm = hhmmInTz(c.at, ownerTz);
    const sort = new Date(c.at).getTime();
    push(day, {
      key: `deadline:${sort}:${c.kind || c.title || ""}`,
      kind: "deadline",
      sort,
      title: c.title || "Deadline",
      detail: `${timeInTz(c.at, ownerTz)}${c.detail ? ` — ${c.detail}` : ""}`,
      href: c.href || "dashboard.html",
      hrefLabel: "Open →",
      chip: `${hhmm} ${deadlineChipText(c)}`,
    });
  }

  const videoDueSeen = new Set(
    cutoffs
      .filter((c) => c?.kind === "video" && c.fixture_id != null)
      .map((c) => String(c.fixture_id))
  );
  for (const v of videoDeadlines) {
    if (!v?.at || v.fixture_id == null) continue;
    const fid = String(v.fixture_id);
    if (videoExtFixtureIds.has(fid) || videoDueSeen.has(fid)) continue;
    videoDueSeen.add(fid);
    pushVideoCutoffEvent(push, v, "video");
  }

  for (const m of seasonMonths) {
    const label =
      GPSL_MONTH_LABELS[m.gpsl_month] || m.gpsl_month_label || m.gpsl_month || "Month";
    const monthKey = String(m.gpsl_month || label || "").toLowerCase();
    if (m.unlock_at) {
      const day = ymdInTz(m.unlock_at, ownerTz);
      const hhmm = hhmmInTz(m.unlock_at, ownerTz);
      push(day, {
        key: `gpsl:unlock:${monthKey}`,
        kind: "gpsl",
        sort: new Date(m.unlock_at).getTime(),
        title: `GPSL ${label} unlocks`,
        detail: `${timeInTz(m.unlock_at, ownerTz)} · play month opens (UK lock cycle: ${formatUkDateTime(m.unlock_at)} UK)`,
        href: "season_calendar.html",
        hrefLabel: "Season Calendar →",
        chip: `${hhmm} Unlock`,
      });

      if (monthKey === "pre_season" || monthKey === "june") {
        push(day, {
          key: `transfer:guide:open:${monthKey}`,
          kind: "transfer",
          sort: new Date(m.unlock_at).getTime() + 1,
          title:
            monthKey === "pre_season"
              ? "Pre-season transfer window (guide)"
              : "Summer transfer window opens (guide)",
          detail:
            "Season guide: transfers are normally open pre-season through August (and again in January). Live open/closed is admin-controlled — confirm on Transfer Centre.",
          href: "transfer_center.html",
          hrefLabel: "Transfer Centre →",
          chip: `${hhmm} Transfers`,
          chipTitle: "Transfer window (season guide)",
        });
      } else if (monthKey === "january") {
        push(day, {
          key: "transfer:guide:open:january",
          kind: "transfer",
          sort: new Date(m.unlock_at).getTime() + 1,
          title: "January transfer window opens (guide)",
          detail:
            "Season guide: January transfer window. Live open/closed is admin-controlled — confirm on Transfer Centre.",
          href: "transfer_center.html",
          hrefLabel: "Transfer Centre →",
          chip: `${hhmm} Transfers`,
          chipTitle: "January transfer window (season guide)",
        });
      } else if (monthKey === "september") {
        push(day, {
          key: "transfer:guide:close:summer",
          kind: "transfer",
          sort: new Date(m.unlock_at).getTime() + 1,
          title: "Summer transfer window ends (guide)",
          detail:
            "Season guide: summer window (Jun–Aug) is closed from September. Confirm live status on Transfer Centre.",
          href: "transfer_center.html",
          hrefLabel: "Transfer Centre →",
          chip: `${hhmm} TW ends`,
          chipTitle: "Summer transfer window ends (guide)",
        });
      } else if (monthKey === "february") {
        push(day, {
          key: "transfer:guide:close:january",
          kind: "transfer",
          sort: new Date(m.unlock_at).getTime() + 1,
          title: "January transfer window ends (guide)",
          detail:
            "Season guide: January window is closed from February. Confirm live status on Transfer Centre.",
          href: "transfer_center.html",
          hrefLabel: "Transfer Centre →",
          chip: `${hhmm} TW ends`,
          chipTitle: "January transfer window ends (guide)",
        });
      }
    }
    if (m.lock_at) {
      const day = ymdInTz(m.lock_at, ownerTz);
      const hhmm = hhmmInTz(m.lock_at, ownerTz);
      push(day, {
        key: `gpsl:lock:${monthKey}`,
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

  if (marketSettings?.transfer_window_open) {
    const today = todayYmd(ownerTz);
    push(today, {
      key: "transfer:live",
      kind: "transfer",
      sort: Date.now(),
      title: "Transfer window open (live)",
      detail: "The transfer window is open right now — list, bid, and manage offers.",
      href: "transfer_center.html",
      hrefLabel: "Transfer Centre →",
      chip: "Window open",
      chipTitle: "Transfer window is open live",
    });
  }

  for (const a of specialAuctions) {
    if (!a?.start_time) continue;
    const typeLabel = AUCTION_TYPE_LABELS[a.auction_type] || "Special auction";
    const title = a.title || typeLabel;
    const href = specialAuctionHref(a);
    if (claimAuctionStart(a.start_time)) {
      const day = ymdInTz(a.start_time, ownerTz);
      const hhmm = hhmmInTz(a.start_time, ownerTz);
      const live =
        a.status === "active" ||
        (new Date(a.start_time).getTime() <= Date.now() &&
          (!a.end_time || new Date(a.end_time).getTime() > Date.now()));
      push(day, {
        key: `auction:special:${a.id}`,
        kind: "auction",
        sort: new Date(a.start_time).getTime(),
        title: live ? `${title} — live` : title,
        detail: `${typeLabel} · ${timeInTz(a.start_time, ownerTz)}${
          a.auction_type === "snap"
            ? " · snap finish is secret"
            : a.end_time
              ? ` → ${timeInTz(a.end_time, ownerTz)}`
              : ""
        }`,
        href,
        hrefLabel: "Open auction →",
        chip: `${hhmm} ${a.auction_type === "blind_gauntlet" ? "Gauntlet" : "Special"}`,
        chipTitle: `${typeLabel}: ${title}`,
      });
    }
    if (a.auction_type !== "snap" && a.end_time) {
      const day = ymdInTz(a.end_time, ownerTz);
      const hhmm = hhmmInTz(a.end_time, ownerTz);
      push(day, {
        key: `auction:special:end:${a.id}`,
        kind: "auction",
        sort: new Date(a.end_time).getTime(),
        title: `${title} ends`,
        detail: `${typeLabel} scheduled end · ${timeInTz(a.end_time, ownerTz)}`,
        href,
        hrefLabel: "Open auction →",
        chip: `${hhmm} Auc. end`,
        chipTitle: `${title} ends`,
      });
    }
  }

  for (const ev of plannedEvents) {
    if (!ev?.starts_at || !PLANNED_AUCTION_KINDS.has(ev.kind)) continue;
    if (!claimAuctionStart(ev.starts_at)) continue;
    const day = ymdInTz(ev.starts_at, ownerTz);
    const hhmm = hhmmInTz(ev.starts_at, ownerTz);
    const link = ev.link_href
      ? { href: ev.link_href, label: "Open →" }
      : PLANNED_DEFAULT_LINK[ev.kind];
    const chipWord = PLANNED_CHIP[ev.kind] || "Auction";
    push(day, {
      key: `auction:planned:${ev.id}`,
      kind: "auction",
      sort: new Date(ev.starts_at).getTime(),
      title: ev.title || chipWord,
      detail: `${timeInTz(ev.starts_at, ownerTz)}${
        ev.ends_at ? ` → ${timeInTz(ev.ends_at, ownerTz)}` : ""
      }${ev.detail ? ` — ${ev.detail}` : ""}`,
      href: link?.href || "season_calendar.html",
      hrefLabel: link?.label || "Season Calendar →",
      chip: `${hhmm} ${chipWord}`,
      chipTitle: ev.title || chipWord,
    });
  }

  const pushArmed = (enabled, startIso, key, title, href, chipWord) => {
    if (!enabled || !startIso) return;
    if (!claimAuctionStart(startIso)) return;
    const day = ymdInTz(startIso, ownerTz);
    const hhmm = hhmmInTz(startIso, ownerTz);
    push(day, {
      key,
      kind: "auction",
      sort: new Date(startIso).getTime(),
      title,
      detail: `${timeInTz(startIso, ownerTz)} · armed start time`,
      href,
      hrefLabel: "Open →",
      chip: `${hhmm} ${chipWord}`,
      chipTitle: title,
    });
  };
  const gs = marketSettings || {};
  pushArmed(
    gs.draft_auction_enabled,
    gs.draft_auction_start_time,
    "auction:armed:player",
    "Player draft auction",
    "draftauction.html",
    "Draft"
  );
  pushArmed(
    gs.manager_draft_auction_enabled,
    gs.manager_draft_auction_start_time,
    "auction:armed:manager",
    "Manager draft auction",
    "manager_draftauction.html",
    "Mgr draft"
  );
  pushArmed(
    gs.club_auction_enabled,
    gs.club_auction_start_time,
    "auction:armed:club",
    "Club auction",
    "club_auction.html",
    "Club auc."
  );

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

function ymKey(y, m) {
  return `${y}-${String(m).padStart(2, "0")}`;
}

/** Months offered in the dropdown (season span if known, else ±18 around view). */
function monthSelectBounds() {
  let minY = viewYear;
  let minM = viewMonth;
  let maxY = viewYear;
  let maxM = viewMonth;

  const bump = (y, m, delta) => {
    let mm = m + delta;
    let yy = y;
    while (mm < 1) {
      mm += 12;
      yy -= 1;
    }
    while (mm > 12) {
      mm -= 12;
      yy += 1;
    }
    return [yy, mm];
  };

  const considerIso = (iso) => {
    if (!iso) return;
    const day = ymdInTz(iso, ownerTz || UK);
    if (!day) return;
    const [y, m] = day.split("-").map(Number);
    if (!y || !m) return;
    if (y < minY || (y === minY && m < minM)) {
      minY = y;
      minM = m;
    }
    if (y > maxY || (y === maxY && m > maxM)) {
      maxY = y;
      maxM = m;
    }
  };

  for (const m of seasonMonths || []) {
    considerIso(m.unlock_at);
    considerIso(m.lock_at);
  }
  for (const f of fixtures || []) considerIso(f.agreed_kickoff_at);
  for (const c of cutoffs || []) considerIso(c?.at);
  for (const v of videoDeadlines || []) considerIso(v?.at);
  for (const a of specialAuctions || []) {
    considerIso(a.start_time);
    considerIso(a.end_time);
  }
  for (const ev of plannedEvents || []) {
    considerIso(ev.starts_at);
    considerIso(ev.ends_at);
  }
  const gs = marketSettings || {};
  considerIso(gs.draft_auction_start_time);
  considerIso(gs.manager_draft_auction_start_time);
  considerIso(gs.club_auction_start_time);

  // Always include a usable window around the current view / today.
  const today = todayYmd(ownerTz || UK);
  const [ty, tm] = (today || "").split("-").map(Number);
  if (ty && tm) {
    const [aY, aM] = bump(ty, tm, -6);
    const [bY, bM] = bump(ty, tm, 18);
    if (aY < minY || (aY === minY && aM < minM)) {
      minY = aY;
      minM = aM;
    }
    if (bY > maxY || (bY === maxY && bM > maxM)) {
      maxY = bY;
      maxM = bM;
    }
  }

  // Ensure current view is inside the list.
  if (viewYear < minY || (viewYear === minY && viewMonth < minM)) {
    minY = viewYear;
    minM = viewMonth;
  }
  if (viewYear > maxY || (viewYear === maxY && viewMonth > maxM)) {
    maxY = viewYear;
    maxM = viewMonth;
  }

  return { minY, minM, maxY, maxM };
}

function syncMonthSelect() {
  const sel = document.getElementById("ocMonthSelect");
  if (!sel) return;
  const { minY, minM, maxY, maxM } = monthSelectBounds();
  const current = ymKey(viewYear, viewMonth);
  const opts = [];
  let y = minY;
  let m = minM;
  while (y < maxY || (y === maxY && m <= maxM)) {
    opts.push(`<option value="${ymKey(y, m)}">${monthLabel(y, m)}</option>`);
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
  }
  sel.innerHTML = opts.join("");
  if (![...sel.options].some((o) => o.value === current)) {
    const extra = document.createElement("option");
    extra.value = current;
    extra.textContent = monthLabel(viewYear, viewMonth);
    sel.appendChild(extra);
  }
  sel.value = current;
}

function goToMonth(y, m) {
  if (!y || !m || m < 1 || m > 12) return;
  if (y === viewYear && m === viewMonth) return;
  viewYear = y;
  viewMonth = m;
  selectedYmd = null;
  focusEventKey = null;
  renderGrid();
  renderPanel();
}

function renderGrid() {
  const grid = document.getElementById("ocGrid");
  syncMonthSelect();
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
      const expanded = c.ymd === selectedYmd;
      const shown = expanded ? events : events.slice(0, 2);
      const more = expanded ? 0 : Math.max(0, events.length - shown.length);
      const chipHtml = shown
        .map(
          (ev) =>
            `<span class="oc-chip oc-chip--${escapeHtml(ev.kind)}" data-ev-key="${escapeHtml(
              ev.key
            )}" title="${escapeHtml(ev.chipTitle || ev.title)}">${escapeHtml(
              ev.chip || ev.title
            )}</span>`
        )
        .join("");
      const overflowKey = more > 0 && events[2] ? events[2].key : "";
      const extra =
        more > 0
          ? `<span class="oc-more" data-ev-key="${escapeHtml(
              overflowKey
            )}">+${more} more</span>`
          : "";
      const cls = [
        "oc-day",
        c.outside ? "is-outside" : "",
        c.ymd === today ? "is-today" : "",
        expanded ? "is-selected" : "",
        expanded && events.length > 2 ? "is-expanded" : "",
        hasAvail ? "has-avail" : "",
      ]
        .filter(Boolean)
        .join(" ");
      return `
        <div class="${cls}" data-ymd="${c.ymd}" role="button" tabindex="0" aria-label="${c.ymd}">
          <div class="oc-day-num">${c.day}</div>
          <div class="oc-chips">${chipHtml}${extra}</div>
        </div>`;
    })
    .join("");

  grid.querySelectorAll(".oc-day").forEach((cell) => {
    const activate = (e) => {
      const hit = e.target?.closest?.("[data-ev-key]");
      selectedYmd = cell.getAttribute("data-ymd");
      focusEventKey = hit?.getAttribute?.("data-ev-key") || null;
      renderGrid();
      renderPanel();
      zoomToFocusedEvent();
    };
    cell.addEventListener("click", activate);
    cell.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        activate(e);
      }
    });
  });
}

function zoomToFocusedEvent() {
  if (!focusEventKey) return;
  const panel = document.getElementById("ocPanel");
  const body = document.getElementById("ocPanelBody");
  if (!body) return;
  const esc =
    typeof CSS !== "undefined" && CSS.escape
      ? CSS.escape(focusEventKey)
      : focusEventKey.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  const el = body.querySelector(`[data-ev-key="${esc}"]`);
  if (!el) return;
  panel?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  el.scrollIntoView({ behavior: "smooth", block: "nearest" });
  el.classList.remove("is-focus");
  // re-trigger animation
  void el.offsetWidth;
  el.classList.add("is-focus");
  window.setTimeout(() => el.classList.remove("is-focus"), 1600);
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
      <div class="oc-event" data-ev-key="avail">
        <span class="oc-event-kind oc-event-kind--avail">AVAILABILITY</span>
        <b>Usually free</b>
        <div class="detail">${escapeHtml(availLine)} (${escapeHtml(ownerTz)})</div>
        <a href="owner_details.html">Edit on Owner Details →</a>
      </div>`);
  } else {
    parts.push(`
      <div class="oc-event" data-ev-key="avail">
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
      const focused = focusEventKey && ev.key === focusEventKey ? " is-focus" : "";
      parts.push(`
        <div class="oc-event${focused}" data-ev-key="${escapeHtml(ev.key)}">
          <span class="oc-event-kind oc-event-kind--${escapeHtml(ev.kind)}">${escapeHtml(
            eventKindLabel(ev.kind)
          )}</span>
          <b>${escapeHtml(ev.title)}</b>
          <div class="detail">${escapeHtml(ev.detail)}</div>
          ${
            ev.ownerLine
              ? `<div class="detail">${escapeHtml(ev.ownerLine)}</div>`
              : ""
          }
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
      "id, home_club_short_name, away_club_short_name, home_club_name, away_club_name, competition_type, cup_code, division, matchday, status, schedule_status, agreed_kickoff_at, gpsl_month"
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

async function resolveVideoGraceHours() {
  try {
    const { data, error } = await supabase.rpc("match_video_missing_fine_grace_hours");
    if (!error && Number.isFinite(Number(data)) && Number(data) > 0) {
      return Number(data);
    }
  } catch {
    /* default */
  }
  return 72;
}

/**
 * First video-upload deadlines for played fixtures still missing our side's video.
 * Due = GPSL month lock + grace hours. Does NOT invent the +24h extension —
 * that only appears from Club Wire once a point is suspended (missed first due).
 */
async function loadVideoDeadlines() {
  const me = (myClub.short || "").trim().toUpperCase();
  if (!me) return [];

  videoGraceHours = await resolveVideoGraceHours();

  const { data: rows, error } = await supabase
    .from("competition_fixtures_public")
    .select(
      "id, home_club_short_name, away_club_short_name, status, gpsl_month, competition_type"
    )
    .eq("status", "played");
  if (error) {
    console.warn("owner_calendar video fixtures:", error);
    return [];
  }

  const mine = (rows || []).filter((f) => {
    const h = (f.home_club_short_name || "").trim().toUpperCase();
    const a = (f.away_club_short_name || "").trim().toUpperCase();
    return h === me || a === me;
  });
  if (!mine.length) return [];

  const ids = mine.map((f) => f.id);
  const { data: vids, error: vidErr } = await supabase
    .from("fixture_match_videos")
    .select("fixture_id, side")
    .in("fixture_id", ids);
  if (vidErr) console.warn("owner_calendar fixture_match_videos:", vidErr);

  const hasVideo = new Set();
  for (const v of vids || []) {
    hasVideo.add(`${v.fixture_id}:${v.side}`);
  }

  const lockByMonth = new Map();
  for (const m of seasonMonths || []) {
    const key = String(m.gpsl_month || "").toLowerCase();
    if (key && m.lock_at) lockByMonth.set(key, m.lock_at);
  }

  const now = Date.now();
  const out = [];
  for (const f of mine) {
    const home = (f.home_club_short_name || "").trim().toUpperCase();
    const side = home === me ? "home" : "away";
    if (hasVideo.has(`${f.id}:${side}`)) continue;

    const monthKey = String(f.gpsl_month || "").toLowerCase();
    const lockAt = lockByMonth.get(monthKey);
    if (!lockAt) continue;

    const dueMs = new Date(lockAt).getTime() + videoGraceHours * 3600_000;
    if (!Number.isFinite(dueMs)) continue;
    // Drop stale dues (>7d overdue) — extension chip covers the active suspend window.
    if (dueMs < now - 7 * 86400_000) continue;

    const oppShort =
      side === "home" ? f.away_club_short_name : f.home_club_short_name;
    const opp = clubFull(oppShort, null);
    out.push({
      fixture_id: f.id,
      kind: "video",
      at: new Date(dueMs).toISOString(),
      title: `Upload match video vs ${opp}`,
      detail: `Due ${videoGraceHours}h after GPSL ${monthKey || "month"} lock. Discord upload with Match Day filename (+₿200k). Miss this and a point is suspended for 24h.`,
      href: `matchday.html?fixture=${encodeURIComponent(String(f.id))}`,
    });
  }
  return out;
}

async function loadPlannedAuctionEvents() {
  const { data, error } = await supabase
    .from("gpsl_planned_events")
    .select("id, title, detail, kind, starts_at, ends_at, link_href")
    .eq("visible", true)
    .order("starts_at", { ascending: true })
    .limit(200);
  if (error) {
    console.warn("gpsl_planned_events:", error);
    return [];
  }
  return (data || []).filter((ev) => PLANNED_AUCTION_KINDS.has(ev.kind));
}

async function loadMarketSettings() {
  const { data, error } = await supabase
    .from("global_settings_public")
    .select(
      "transfer_window_open, draft_auction_enabled, draft_auction_start_time, manager_draft_auction_enabled, manager_draft_auction_start_time, club_auction_enabled, club_auction_start_time"
    )
    .maybeSingle();
  if (error) {
    console.warn("global_settings_public:", error);
    return null;
  }
  return data || null;
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
  focusEventKey = null;
  renderGrid();
  renderPanel();
}

function goToday() {
  const t = todayYmd(ownerTz);
  const [y, m] = t.split("-").map(Number);
  viewYear = y;
  viewMonth = m;
  selectedYmd = t;
  focusEventKey = null;
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
  document.getElementById("ocMonthSelect")?.addEventListener("change", (e) => {
    const v = e.target?.value || "";
    const [y, m] = v.split("-").map(Number);
    goToMonth(y, m);
  });

  try {
    const [avail, months, fix, cuts, auctions, planned, settings] =
      await Promise.all([
        loadAvailabilityContext().catch((e) => {
          console.warn(e);
          return null;
        }),
        loadSeasonCalendarMonths(supabase),
        loadClubsMap().then(() => loadMyFixtures()),
        loadCutoffs(),
        loadUpcomingSpecialAuctions(supabase).catch((e) => {
          console.warn(e);
          return [];
        }),
        loadPlannedAuctionEvents().catch((e) => {
          console.warn(e);
          return [];
        }),
        loadMarketSettings().catch((e) => {
          console.warn(e);
          return null;
        }),
      ]);

    ownerTz = avail?.timezone || UK;
    weeklySlots = Array.isArray(avail?.weekly_slots) ? avail.weekly_slots : [];
    seasonMonths = months || [];
    fixtures = fix || [];
    cutoffs = cuts || [];
    specialAuctions = auctions || [];
    plannedEvents = planned || [];
    marketSettings = settings;
    videoDeadlines = await loadVideoDeadlines().catch((e) => {
      console.warn(e);
      return [];
    });

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
