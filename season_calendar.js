/**
 * Season calendar — month-by-month guide for owners (pre-season + Aug–May).
 */
import { supabase, initGlobal, getAuthUserFast } from "./global.js";
import {
  loadCalendarStatus,
  loadSeasonCalendarMonths,
  formatUkDateTime,
  navGpslMonthDisplay,
  isPreSeasonPhase,
} from "./competition_calendar.js";
import { GPSL_MONTH_LABELS, CUP_LABELS } from "./competition.js";
import { formatSeasonStripLabel } from "./season_transfer_schedule.js";

const CUP_NAME = {
  ...CUP_LABELS,
  spoon: "Spoon",
  bowl: "Bowl",
};

/** League matchday ranges by GPSL month (competition_matchday_calendar). */
const LEAGUE_BY_MONTH = {
  august: { from: 1, to: 3 },
  september: { from: 4, to: 7 },
  october: { from: 8, to: 11 },
  november: { from: 12, to: 15 },
  december: { from: 16, to: 19 },
  january: { from: 20, to: 23 },
  february: { from: 24, to: 27 },
  march: { from: 28, to: 31 },
  april: { from: 32, to: 35 },
  may: { from: 36, to: 38 },
};

/** Cup rounds by GPSL month (competition_cup_round_schedule). */
const CUP_BY_MONTH = {
  august: [{ cup: "shield", label: "Shield — Last 32" }],
  september: [
    { cup: "super8", label: "Super8 — Quarter-final (1st leg)" },
    { cup: "spoon", label: "Spoon — Quarter-final (1st leg)" },
    { cup: "plate", label: "Plate — Last 16" },
    { cup: "shield", label: "Shield — Last 16" },
  ],
  october: [
    { cup: "super8", label: "Super8 — Quarter-final (2nd leg)" },
    { cup: "spoon", label: "Spoon — Quarter-final (2nd leg)" },
    { cup: "plate", label: "Plate — Quarter-final" },
    { cup: "shield", label: "Shield — Quarter-final" },
  ],
  november: [
    { cup: "super8", label: "Super8 — Semi-final" },
    { cup: "spoon", label: "Spoon — Semi-final" },
    { cup: "plate", label: "Plate — Semi-final" },
    { cup: "shield", label: "Shield — Semi-final" },
  ],
  december: [
    { cup: "super8", label: "Super8 — Final" },
    { cup: "spoon", label: "Spoon — Final" },
    { cup: "plate", label: "Plate — Final" },
    { cup: "shield", label: "Shield — Final" },
    { cup: "league_cup", label: "League Cup — Last 64" },
  ],
  january: [{ cup: "league_cup", label: "League Cup — Last 32" }],
  february: [{ cup: "league_cup", label: "League Cup — Last 16" }],
  march: [{ cup: "league_cup", label: "League Cup — Quarter-final" }],
  april: [{ cup: "league_cup", label: "League Cup — Semi-final" }],
  may: [{ cup: "league_cup", label: "League Cup — Final" }],
};

/** Transfer window by calendar month key (owner-facing season guide). */
const TRANSFER_BY_MONTH = {
  june: "open",
  july: "open",
  august: "open",
  september: "closed",
  october: "closed",
  november: "closed",
  december: "closed",
  january: "open",
  february: "closed",
  march: "closed",
  april: "closed",
  may: "closed",
};

const SEASON_MONTH_ORDER = [
  "june",
  "july",
  "august",
  "september",
  "october",
  "november",
  "december",
  "january",
  "february",
  "march",
  "april",
  "may",
];

const MONTH_LABELS = {
  june: "June",
  july: "July",
  ...GPSL_MONTH_LABELS,
};

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function leagueLabel(monthKey) {
  const range = LEAGUE_BY_MONTH[monthKey];
  if (!range) return null;
  if (range.from === range.to) return `League Matches ${range.from}`;
  return `League Matches ${range.from}–${range.to}`;
}

function nextPlayMonth(monthKey) {
  const i = SEASON_MONTH_ORDER.indexOf(monthKey);
  if (i < 0 || i >= SEASON_MONTH_ORDER.length - 1) return null;
  const next = SEASON_MONTH_ORDER[i + 1];
  if (next === "june" || next === "july") return null;
  return next;
}

function messagingDeadlineText(monthKey) {
  if (monthKey === "june" || monthKey === "july") {
    return "Message opponents & arrange kick-offs from when fixtures are published (including pre-season).";
  }
  const next = nextPlayMonth(monthKey);
  if (!next) {
    return "Finish arranging any remaining May fixtures before the season calendar locks.";
  }
  const nextLabel = MONTH_LABELS[next] || next;
  const thisLabel = MONTH_LABELS[monthKey] || monthKey;
  return `Arrange ${nextLabel} fixtures before ${thisLabel} locks (primary messaging / arrangement deadline).`;
}

function staticEventsForMonth(monthKey) {
  const events = [];

  if (monthKey === "june" || monthKey === "july") {
    events.push({
      kind: "phase",
      text: "Pre-season",
      href: null,
    });
  }

  const league = leagueLabel(monthKey);
  if (league) {
    events.push({
      kind: "league",
      text: league,
      href: "fixtures.html",
    });
  }

  for (const cup of CUP_BY_MONTH[monthKey] || []) {
    events.push({
      kind: "cup",
      text: cup.label,
      href: `cups.html?cup=${encodeURIComponent(cup.cup)}`,
      cup: cup.cup,
    });
  }

  const tw = TRANSFER_BY_MONTH[monthKey];
  if (tw === "open") {
    events.push({
      kind: "transfer-open",
      text: "Transfer window open",
      href: "transfer_center.html",
    });
  } else if (tw === "closed") {
    events.push({
      kind: "transfer-closed",
      text: "Transfer window closed",
      href: "transfer_center.html",
    });
  }

  if (monthKey === "june" || monthKey === "july" || monthKey === "january") {
    events.push({
      kind: "manager-auction",
      text: "Manager auctions",
      href: "manager_draftauction.html",
    });
  }

  events.push({
    kind: "deadline",
    text: messagingDeadlineText(monthKey),
    href: "learning_gpsl.html#match-scheduling",
  });

  return events;
}

function parseDraftScheduleDedupe(dedupeKey) {
  const m = String(dedupeKey || "").match(
    /^draft_scheduled:(player|manager):(.+):(\d+):([A-Za-z0-9_]+)$/
  );
  if (!m) return null;
  return { kind: m[1], createdAtHint: m[2] };
}

function monthKeyFromIso(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    month: "long",
  }).formatToParts(d);
  const month = parts.find((p) => p.type === "month")?.value?.toLowerCase();
  return month || null;
}

async function loadLiveOverlays(status) {
  const nowIso = new Date().toISOString();
  const [
    settingsRes,
    inboxRes,
    specialRes,
    wcRes,
    myNationRes,
    intlFixRes,
  ] = await Promise.all([
    supabase
      .from("global_settings_public")
      .select(
        "transfer_window_open, draft_auction_enabled, draft_auction_start_time, draft_bidding_open, manager_draft_auction_enabled, manager_draft_bidding_open, league_phase"
      )
      .maybeSingle(),
    supabase
      .from("competition_inbox")
      .select("dedupe_key, created_at, title, body")
      .eq("message_type", "draft_scheduled")
      .like("dedupe_key", "draft_scheduled:%")
      .order("created_at", { ascending: false })
      .limit(40),
    supabase
      .from("special_auctions")
      .select("id, status, start_time, end_time, title")
      .in("status", ["scheduled", "active"])
      .order("start_time", { ascending: true })
      .limit(10),
    supabase
      .from("international_wc_cycle_public")
      .select("*")
      .order("cycle_no", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.from("international_my_nation_public").select("*").maybeSingle(),
    supabase
      .from("international_fixtures")
      .select(
        "id, home_nation, away_nation, phase, played, played_at, cycle_id, season_id"
      )
      .eq("played", false)
      .order("id", { ascending: true })
      .limit(120),
  ]);

  const byMonth = Object.fromEntries(
    SEASON_MONTH_ORDER.map((k) => [k, []])
  );

  const settings = settingsRes.data || {};
  const draftStart = settings.draft_auction_start_time;
  if (draftStart && settings.draft_auction_enabled) {
    const mk = monthKeyFromIso(draftStart);
    if (mk && byMonth[mk]) {
      const live = settings.draft_bidding_open === true;
      byMonth[mk].push({
        kind: "draft",
        text: live
          ? `Player draft auction — live (started ${formatUkDateTime(draftStart)} UK)`
          : `Player draft auction — scheduled ${formatUkDateTime(draftStart)} UK`,
        href: "draftauction.html",
        live,
      });
    }
  }
  if (draftStart && settings.manager_draft_auction_enabled) {
    const mk = monthKeyFromIso(draftStart);
    if (mk && byMonth[mk]) {
      const live = settings.manager_draft_bidding_open === true;
      byMonth[mk].push({
        kind: "manager-auction",
        text: live
          ? `Manager draft auction — live (started ${formatUkDateTime(draftStart)} UK)`
          : `Manager draft auction — scheduled ${formatUkDateTime(draftStart)} UK`,
        href: "manager_draftauction.html",
        live,
      });
    }
  }

  const seenDraftKeys = new Set();
  for (const row of inboxRes.data || []) {
    const parsed = parseDraftScheduleDedupe(row.dedupe_key);
    if (!parsed) continue;
    const when = parsed.createdAtHint || row.created_at;
    const mk = monthKeyFromIso(when);
    if (!mk || !byMonth[mk]) continue;
    const dedupe = `${parsed.kind}:${when}`;
    if (seenDraftKeys.has(dedupe)) continue;
    seenDraftKeys.add(dedupe);
    const label =
      parsed.kind === "manager" ? "Manager draft" : "Player draft";
    byMonth[mk].push({
      kind: parsed.kind === "manager" ? "manager-auction" : "draft",
      text: `${label} scheduled — ${formatUkDateTime(when)} UK`,
      href:
        parsed.kind === "manager"
          ? "manager_draftauction.html"
          : "draftauction.html",
    });
  }

  for (const row of specialRes.data || []) {
    const mk = monthKeyFromIso(row.start_time);
    if (!mk || !byMonth[mk]) continue;
    const live =
      row.status === "active" ||
      (row.start_time <= nowIso &&
        row.end_time &&
        row.end_time > nowIso);
    byMonth[mk].push({
      kind: "special",
      text: live
        ? `Special auction live${row.title ? ` — ${row.title}` : ""}`
        : `Special auction — ${formatUkDateTime(row.start_time)} UK`,
      href: "special_auction.html",
      live,
    });
  }

  const wc = wcRes.data;
  const myNation = myNationRes.data || null;
  const myNationCode = myNation?.code || null;
  const internationalMine = [];

  if (wc && String(wc.status || "").toLowerCase() !== "complete") {
    const noteParts = [];
    if (wc.cycle_no != null) noteParts.push(`Cycle ${wc.cycle_no}`);
    if (wc.label) noteParts.push(String(wc.label));
    if (wc.status) noteParts.push(String(wc.status).replace(/_/g, " "));
    if (wc.finals_after_season_label) {
      noteParts.push(`finals after ${wc.finals_after_season_label}`);
    }
    const wcText =
      noteParts.length > 0
        ? `World Cup — ${noteParts.join(" · ")}`
        : "World Cup cycle active";
    for (const mk of ["june", "july", "august"]) {
      byMonth[mk].push({
        kind: "world-cup",
        text: wcText,
        href: "world_cup.html",
      });
    }
  }

  // International fixtures have no kick-off column — pin owner's unplayed ties
  // onto the current GPSL month (or pre-season).
  let pinMonth = "august";
  if (isPreSeasonPhase(status)) pinMonth = "july";
  else if (status?.active_gpsl_month) {
    pinMonth = String(status.active_gpsl_month).toLowerCase();
  } else if (status?.next_gpsl_month) {
    pinMonth = String(status.next_gpsl_month).toLowerCase();
  }

  for (const fix of intlFixRes.data || []) {
    const home = fix.home_nation || "?";
    const away = fix.away_nation || "?";
    const mine =
      myNationCode &&
      (String(home).toUpperCase() === String(myNationCode).toUpperCase() ||
        String(away).toUpperCase() === String(myNationCode).toUpperCase());
    if (!mine) continue;
    const phase = fix.phase ? String(fix.phase).replace(/_/g, " ") : "fixture";
    const ev = {
      kind: "international",
      text: `International (${phase}): ${home} vs ${away}`,
      href: "national_team.html",
      mine: true,
    };
    internationalMine.push(ev);
    if (byMonth[pinMonth]) byMonth[pinMonth].push(ev);
  }

  return {
    byMonth,
    transferLiveOpen: settings.transfer_window_open === true,
    leaguePhase: settings.league_phase || null,
    myNation,
    internationalMine,
  };
}

async function loadClubFixturesByMonth(user) {
  const empty = { clubShort: null, clubName: null, byMonth: {}, rows: [] };
  if (!user) return empty;
  try {
    const { data: club } = await supabase
      .from("Clubs")
      .select("ShortName, Club")
      .eq("owner_id", user.id)
      .maybeSingle();
    const clubShort = club?.ShortName || null;
    if (!clubShort) return empty;

    const { data, error } = await supabase.rpc("club_fixtures_my_club");
    if (error) {
      console.warn("season calendar club fixtures:", error);
      return { ...empty, clubShort, clubName: club?.Club || clubShort };
    }
    const rows = Array.isArray(data) ? data : [];
    const byMonth = {};
    for (const f of rows) {
      const mk = String(f.gpsl_month || "").toLowerCase();
      if (!mk) continue;
      if (!byMonth[mk]) byMonth[mk] = [];
      byMonth[mk].push(f);
    }
    return {
      clubShort,
      clubName: club?.Club || clubShort,
      byMonth,
      rows,
    };
  } catch (err) {
    console.warn("season calendar club fixtures:", err);
    return empty;
  }
}

function formatClubFixtureLine(f) {
  const home = f.home_club_short_name || f.home_short || "?";
  const away = f.away_club_short_name || f.away_short || "?";
  let comp = "League";
  if (f.competition_type === "cup" || f.cup_code) {
    comp = CUP_NAME[f.cup_code] || f.cup_code || "Cup";
    if (f.cup_round != null) comp += ` · R${f.cup_round}`;
  } else if (f.matchday != null) {
    comp = `MD ${f.matchday}`;
  }
  const score =
    f.home_goals != null && f.away_goals != null
      ? ` ${f.home_goals}–${f.away_goals}`
      : "";
  return { home, away, comp, score, ko: "", id: f.id || f.fixture_id };
}

function isCurrentMonth(monthKey, status) {
  if (!status) return false;
  if (isPreSeasonPhase(status)) {
    return monthKey === "june" || monthKey === "july";
  }
  if (status.calendar_phase === "in_month") {
    return (
      String(status.active_gpsl_month || "").toLowerCase() === monthKey
    );
  }
  if (status.calendar_phase === "between_months") {
    return String(status.next_gpsl_month || "").toLowerCase() === monthKey;
  }
  return false;
}

function renderEventItem(ev) {
  const cls = [
    "sc-event",
    `sc-event--${ev.kind}`,
    ev.live ? "sc-event--live" : "",
    ev.mine ? "sc-event--mine" : "",
  ]
    .filter(Boolean)
    .join(" ");
  const inner = escapeHtml(ev.text);
  if (ev.href) {
    return `<li class="${cls}"><a href="${escapeHtml(ev.href)}">${inner}</a></li>`;
  }
  return `<li class="${cls}"><span>${inner}</span></li>`;
}

function renderClubFixtures(fixtures) {
  if (!fixtures?.length) return "";
  const items = fixtures
    .map((f) => {
      const line = formatClubFixtureLine(f);
      const href = line.id
        ? `fixture_schedule.html?fixture=${encodeURIComponent(line.id)}`
        : "club_fixtures.html";
      return (
        `<li class="sc-event sc-event--club-fixture sc-event--mine">` +
        `<a href="${escapeHtml(href)}">` +
        `<span class="sc-club-comp">${escapeHtml(line.comp)}</span> ` +
        `<span class="mine">${escapeHtml(line.home)}</span> vs ` +
        `<span class="mine">${escapeHtml(line.away)}</span>` +
        `${escapeHtml(line.score)}${escapeHtml(line.ko)}` +
        `</a></li>`
      );
    })
    .join("");
  return (
    `<div class="sc-club-block">` +
    `<h3 class="sc-club-heading">Your fixtures</h3>` +
    `<ul class="sc-events sc-events--club">${items}</ul>` +
    `</div>`
  );
}

function renderMonthCard(monthKey, ctx) {
  const label = MONTH_LABELS[monthKey] || monthKey;
  const isPre = monthKey === "june" || monthKey === "july";
  const current = isCurrentMonth(monthKey, ctx.status);
  const calRow = ctx.calendarMonths.find(
    (r) => String(r.gpsl_month || "").toLowerCase() === monthKey
  );

  const staticEvents = staticEventsForMonth(monthKey);
  const liveEvents = ctx.live.byMonth[monthKey] || [];
  // Prefer live draft/special overlays; keep static manager-auction in preseason/Jan
  const events = [...staticEvents, ...liveEvents];

  let windowNote = "";
  if (calRow?.unlock_at || calRow?.lock_at) {
    windowNote =
      `<p class="sc-window">` +
      (calRow.unlock_at
        ? `Unlocks ${escapeHtml(formatUkDateTime(calRow.unlock_at))} UK`
        : "") +
      (calRow.unlock_at && calRow.lock_at ? " · " : "") +
      (calRow.lock_at
        ? `Locks ${escapeHtml(formatUkDateTime(calRow.lock_at))} UK`
        : "") +
      `</p>`;
  } else if (isPre && ctx.status?.anchor_unlock_at) {
    windowNote = `<p class="sc-window">GPSL August unlocks ${escapeHtml(
      formatUkDateTime(ctx.status.anchor_unlock_at)
    )} UK</p>`;
  }

  const clubFx = ctx.club.byMonth[monthKey] || [];

  return (
    `<article class="sc-month${isPre ? " sc-month--pre" : ""}${
      current ? " sc-month--current" : ""
    }" id="month-${escapeHtml(monthKey)}" data-month="${escapeHtml(monthKey)}">` +
    `<header class="sc-month-head">` +
    `<h2>${escapeHtml(label)}</h2>` +
    (current ? `<span class="sc-now-badge">Now</span>` : "") +
    (isPre ? `<span class="sc-pre-badge">Pre-season</span>` : "") +
    `</header>` +
    windowNote +
    `<ul class="sc-events">${events.map(renderEventItem).join("")}</ul>` +
    renderClubFixtures(clubFx) +
    `</article>`
  );
}

function showError(msg) {
  const el = document.getElementById("seasonCalendarError");
  if (!el) return;
  el.textContent = msg;
  el.style.display = "block";
}

async function loadSeasonLabel() {
  const { data } = await supabase
    .from("competition_seasons")
    .select("label")
    .eq("is_current", true)
    .maybeSingle();
  return formatSeasonStripLabel(data?.label);
}

async function renderPage(user) {
  const root = document.getElementById("seasonCalendarRoot");
  if (!root) return;

  root.innerHTML = `<p class="sc-loading">Loading season calendar…</p>`;

  const status = await loadCalendarStatus(supabase);
  const [calendarMonths, live, club, seasonLabel] = await Promise.all([
    loadSeasonCalendarMonths(supabase),
    loadLiveOverlays(status),
    loadClubFixturesByMonth(user),
    loadSeasonLabel(),
  ]);

  const ctx = { status, calendarMonths, live, club };
  const monthLabel = navGpslMonthDisplay(status);
  const meta = document.getElementById("seasonCalendarMeta");
  if (meta) {
    const bits = [seasonLabel];
    if (monthLabel) bits.push(`Current: ${monthLabel}`);
    if (club.clubShort) bits.push(`Your club: ${club.clubShort}`);
    if (live.myNation?.name || live.myNation?.code) {
      bits.push(`Nation: ${live.myNation.name || live.myNation.code}`);
    }
    bits.push(
      live.transferLiveOpen
        ? "Transfer window is open now"
        : "Transfer window is closed now"
    );
    meta.textContent = bits.filter(Boolean).join(" · ");
  }

  const jump = SEASON_MONTH_ORDER.map((mk) => {
    const current = isCurrentMonth(mk, status);
    return (
      `<a class="sc-jump${current ? " sc-jump--current" : ""}" href="#month-${escapeHtml(
        mk
      )}">${escapeHtml(MONTH_LABELS[mk])}</a>`
    );
  }).join("");

  root.innerHTML =
    `<nav class="sc-jump-nav" aria-label="Jump to month">${jump}</nav>` +
    `<div class="sc-grid">` +
    SEASON_MONTH_ORDER.map((mk) => renderMonthCard(mk, ctx)).join("") +
    `</div>` +
    `<p class="sc-footnote">` +
    `League matchdays follow the fixed GPSL calendar (Aug 1–3, then four per month Sep–Apr, May 36–38). ` +
    `Cup rounds match the published schedule. Live draft / special auction / international dates appear when scheduled. ` +
    `Your fixtures are highlighted when you own a club.` +
    `</p>`;
}

async function main() {
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    showError("Sign in to view the season calendar.");
    const root = document.getElementById("seasonCalendarRoot");
    if (root) root.innerHTML = "";
    return;
  }
  try {
    await renderPage(user);
  } catch (err) {
    console.error(err);
    showError(err?.message || "Could not load season calendar.");
  }
}

main();
