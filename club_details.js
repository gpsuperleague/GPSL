// Club Details page

import {
  supabase,
  initGlobal,
  refreshNavClubListingState,
  refreshNavListingIndicators,
} from "./global.js";
import { loadClubsMap, fullClubName, clubPageHref } from "./clubs_lookup.js";
import {
  formatMoney,
  loadCurrentSeason,
  loadActiveSeasonRegistrations,
  divisionSlugForClub,
  LEAGUE_DIVISIONS,
} from "./competition.js";
import { loadCalendarStatus } from "./competition_calendar.js";
import { loadClubKits, renderKitsPanelHtml } from "./club_kits_common.js";
import {
  applyClubDashboardTheme,
  GPSL_THEME_DEFAULTS,
  loadClubDashboardTheme,
  normalizeHexColor,
  normalizeThemeRow,
  normalizeThemeScope,
  renderThemePreviewHtml,
  saveClubDashboardTheme,
  suggestThemeFromKit,
  THEME_SCOPES,
} from "./club_theme_common.js";

let cachedKitRow = null;
let themeDraft = { ...GPSL_THEME_DEFAULTS };
let pageClubShort = null;

const CLUB_SELECT_BASE =
  "ShortName, Club, Stadium, Capacity, Nation";

function formatNationLabel(value) {
  if (value == null || !String(value).trim()) return "";
  const spaced = String(value)
    .trim()
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return spaced
    .split(" ")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function progressDivisionHref(division) {
  if (!division || !LEAGUE_DIVISIONS.includes(division)) return null;
  return `progress.html?division=${encodeURIComponent(division)}`;
}

function fixturesDivisionHref(division) {
  if (!division || !LEAGUE_DIVISIONS.includes(division)) return null;
  return `fixtures.html?division=${encodeURIComponent(division)}`;
}

function gpdbNationHref(nationRaw) {
  const nation = String(nationRaw ?? "").trim();
  if (!nation) return null;
  return `GPDB.html?nation=${encodeURIComponent(nation)}`;
}

function setClubDetailLink(el, href, label) {
  if (!el) return;
  if (!href) {
    el.textContent = label || "—";
    return;
  }
  el.innerHTML = `<a href="${href}" class="club-detail-link club-detail-link--value">${escapeHtml(label || "—")}</a>`;
}

function renderDivisionCell(el, division) {
  if (!el) return;
  if (!division) {
    el.textContent = "Not registered";
    return;
  }
  const tableHref = progressDivisionHref(division);
  const fixturesHref = fixturesDivisionHref(division);
  const label = formatDivisionLabel(division);
  if (!tableHref || !fixturesHref) {
    el.textContent = label;
    return;
  }
  el.innerHTML = `
    <span class="club-detail-division-label">${escapeHtml(label)}</span>
    <div class="club-detail-quick-links">
      <a href="${tableHref}" class="club-detail-link">Table</a>
      <a href="${fixturesHref}" class="club-detail-link">Fixtures</a>
    </div>`;
}

async function loadOwnerClub(userId) {
  return supabase
    .from("Clubs")
    .select(CLUB_SELECT_BASE)
    .eq("owner_id", userId)
    .maybeSingle();
}

function showLoadError(message) {
  const el = document.getElementById("clubDetailsError");
  if (el) {
    el.textContent = message;
    el.hidden = false;
  }
}

function renderChallengeSummary(progress, loadError) {
  const summary = document.getElementById("challengeSummary");
  if (!summary) return;

  if (loadError) {
    summary.textContent = loadError;
    return;
  }

  const items = progress?.challenges || [];
  if (!items.length) {
    summary.textContent = "No active challenges this season.";
    return;
  }

  const complete = items.filter(
    (c) => c.awarded || Number(c.current_value) >= Number(c.target_value)
  ).length;
  summary.textContent = `${complete} of ${items.length} complete · prizes on match confirm`;
}

function renderChallengeGrid(progress, loadError) {
  renderChallengeSummary(progress, loadError);
  const grid = document.getElementById("challengeGrid");
  if (!grid) return;

  if (loadError) {
    grid.innerHTML = `<p class="subsidy-meta">${loadError}</p>`;
    return;
  }

  const items = progress?.challenges || [];
  if (!items.length) {
    grid.innerHTML = "<p class=\"subsidy-meta\">No active challenges this season.</p>";
    return;
  }

  grid.innerHTML = items
    .map((c) => {
      const done = c.awarded || Number(c.current_value) >= Number(c.target_value);
      const status = c.awarded
        ? "Awarded"
        : c.expired
          ? "Expired"
          : done
            ? "Complete"
            : `${c.current_value ?? 0} / ${c.target_value}`;
      return `
        <div class="subsidy-card">
          <h3>${c.title}</h3>
          <p class="subsidy-status">${status}</p>
          <p class="subsidy-meta">${c.window_phase} window · ${formatMoney(Number(c.prize_amount || 0))}</p>
        </div>
      `;
    })
    .join("");
}

function formatDivisionLabel(division) {
  if (!division) return "—";
  if (division === "superleague") return "Super League";
  if (division === "championship_a") return "Championship A";
  if (division === "championship_b") return "Championship B";
  return division;
}

function formatManagerTarget(row) {
  if (!row?.target_label) return "—";
  if (row.target_kind === "max_position" && row.target_value) {
    return `${row.target_label} (finish ≤ ${row.target_value})`;
  }
  return row.target_label;
}

function formatChartBands(row) {
  const parts = [row.boost1_label, row.boost2_label, row.boost3_label].filter(Boolean);
  if (!parts.length) return null;
  return parts.join(" · ");
}

function formatOrdinal(n) {
  const num = Number(n);
  if (!Number.isFinite(num)) return String(n ?? "—");
  const mod10 = num % 10;
  const mod100 = num % 100;
  let suffix = "th";
  if (mod10 === 1 && mod100 !== 11) suffix = "st";
  else if (mod10 === 2 && mod100 !== 12) suffix = "nd";
  else if (mod10 === 3 && mod100 !== 13) suffix = "rd";
  return `${num}${suffix}`;
}

/** Live / archived league position vs manager deal target for Club Details. */
function formatTargetProgress(row) {
  const pos = row?.season_position;
  const posLabel = pos != null ? ` (currently ${formatOrdinal(pos)})` : "";

  if (row?.pending_owner_renewal) {
    const hits = Number(row.deal_target_hits) || 0;
    return {
      text: `Deal complete — renewal available (${hits} target hit${hits === 1 ? "" : "s"})`,
      className: "manager-target--on",
    };
  }

  if (row?.target_met === true) {
    return {
      text: `On target${posLabel}`,
      className: "manager-target--on",
    };
  }
  if (row?.target_met === false) {
    return {
      text: `Off target${posLabel}`,
      className: "manager-target--off",
    };
  }
  if (pos != null) {
    return {
      text: `Position ${formatOrdinal(pos)} — target status unavailable`,
      className: "manager-target--pending",
    };
  }
  return {
    text: "No league position yet this season",
    className: "manager-target--pending",
  };
}

function formatClubTierLabel(tier) {
  if (tier === "big") return "Big club";
  if (tier === "medium") return "Medium club";
  if (tier === "low") return "Low club";
  return tier || "—";
}

function formatPerformanceBand(band) {
  if (!band || band === "—") return "—";
  const labels = {
    on_target: "On target",
    slight: "Slight miss",
    bad: "Bad miss",
    abysmal: "Abysmal miss",
  };
  return labels[band] || band;
}

function performanceBandClass(band) {
  if (!band || band === "on_target") return "expectation-band--on_target";
  if (band === "slight") return "expectation-band--slight";
  if (band === "bad") return "expectation-band--bad";
  if (band === "abysmal") return "expectation-band--abysmal";
  return "";
}

function failurePunishmentNote(tier) {
  const stadium =
    "Gate fill drifts down when below expectation (slight −10%, bad −20%, abysmal −25%).";
  if (tier === "big") {
    return `At season end, one random player from your top four rated may be forced onto the transfer market at market value (perpetual relisting, cannot remove). ${stadium}`;
  }
  if (tier === "medium") {
    return `At season end, one player rated 74–78 who is over 21 may be forced onto the transfer market at market value (perpetual relisting, cannot remove). ${stadium}`;
  }
  return `Low clubs are not subject to underperformance transfer requests. ${stadium}`;
}

function managerLiftNote(data) {
  const baseline = Number(data.baseline_expected_position);
  const combined = Number(data.expected_position);
  const rating = data.manager_rating;
  const tier = data.club_tier;

  if (!Number.isFinite(baseline) || !Number.isFinite(combined)) return "";

  if (tier === "big") {
    return "Big clubs are held to a high standard — manager rating does not lower the bar.";
  }

  const lift = baseline - combined;
  if (lift > 0 && rating) {
    return `Manager rating ${rating} raises expectation by ${lift} place${lift === 1 ? "" : "s"}.`;
  }
  if (rating && tier !== "big") {
    return `Manager rating ${rating} — rating below the lift threshold, so club baseline applies.`;
  }
  return "No manager signed — club baseline applies.";
}

async function loadExpectationSection(clubShortName) {
  const statusEl = document.getElementById("expectationStatus");
  if (!statusEl) return;

  const { data, error } = await supabase.rpc("competition_compute_stadium_fill", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    statusEl.textContent = msg.includes("competition_compute_stadium_fill")
      ? "Run stadium_attendance_v2.sql to enable expectations."
      : msg;
    return;
  }

  if (!data || data.error) {
    statusEl.textContent = data?.error || "Expectation data unavailable.";
    return;
  }

  const baselinePos = data.baseline_expected_position ?? "—";
  const seasonPos = data.expected_position ?? "—";
  const expectedPts = Number(data.expected_points || 0);
  const actualPos = data.actual_position ?? "—";
  const actualPts = Number(data.actual_points || 0);
  const statusReady = data.performance_status_ready !== false && data.performance_band != null;
  const band = statusReady ? data.performance_band : null;
  const tier = data.club_tier || "";
  const prestigeRank = data.prestige_rank ?? "—";
  const liftNote = managerLiftNote(data);
  const deliveryLine = statusReady
    ? `League ${actualPos} · ${actualPts.toFixed(2)} pts`
    : "— (after first month’s fixtures)";
  const performanceLine = statusReady
    ? `<span class="${performanceBandClass(band)}">${formatPerformanceBand(band)}</span>`
    : "—";

  statusEl.innerHTML = `
    <div class="expectation-block">
      <h3>Club expectation</h3>
      <dl class="expectation-dl">
        <dt>Club tier</dt><dd>${formatClubTierLabel(tier)} · prestige rank ${prestigeRank}</dd>
        <dt>Expected finish</dt><dd>League position ${baselinePos}</dd>
      </dl>
      <p class="expectation-note">From 5-year prestige — where the club is expected to finish without manager lift.</p>
    </div>

    <div class="expectation-block">
      <h3>Season expectation</h3>
      <dl class="expectation-dl">
        <dt>Expected finish</dt><dd>League ${seasonPos} · ${expectedPts.toFixed(2)} pts</dd>
        <dt>Current delivery</dt><dd>${deliveryLine}</dd>
        <dt>Performance</dt><dd>${performanceLine}</dd>
      </dl>
      ${liftNote ? `<p class="expectation-note">${liftNote}</p>` : ""}
    </div>

    <div class="expectation-block">
      <h3>Failure punishment</h3>
      <p class="expectation-note">${failurePunishmentNote(tier)}</p>
      <p class="expectation-note">Checked at season archive. See <a href="learning_gpsl.html#club-expectations" style="color:#ff9900;">Learning GPSL</a> and <a href="stadium.html" style="color:#ff9900;">Stadium</a> for full rules.</p>
    </div>
  `;
}

async function isGpslJanuary() {
  const status = await loadCalendarStatus(supabase);
  if (!status?.calendar_configured) return false;
  return String(status.active_gpsl_month || "").toLowerCase() === "january";
}

function formatDealRecord(data) {
  const hits = Number(data?.deal_target_hits);
  const misses = Number(data?.deal_target_misses);
  if (!Number.isFinite(hits) && !Number.isFinite(misses)) return null;
  const h = Number.isFinite(hits) ? hits : 0;
  const m = Number.isFinite(misses) ? misses : 0;
  if (h + m <= 0) return "No completed seasons on this deal yet";
  return `${h} hit · ${m} miss (this deal)`;
}

async function loadManagerSection(clubShortName) {
  const statusEl = document.getElementById("managerStatus");
  const hintEl = document.getElementById("managerHint");
  const listBtn = document.getElementById("listManagerBtn");
  const sackBtn = document.getElementById("sackManagerBtn");
  const renewBtn = document.getElementById("renewManagerBtn");

  const { data, error } = await supabase
    .from("manager_club_status_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .maybeSingle();

  if (error) {
    const msg = String(error.message || "");
    if (statusEl) {
      statusEl.textContent = msg.includes("manager_club_status")
        ? "Run supabase/sql/patches/managers_system.sql (and manager_two_season_deal_eval.sql) to enable managers."
        : msg;
    }
    return;
  }

  if (!data?.manager_id) {
    if (statusEl) {
      statusEl.innerHTML =
        'No manager signed. <a href="MGDB.html" style="color:#ff9900;">Browse MGDB</a> or the manager transfer market.';
    }
    setBtnVisible(listBtn, false);
    setBtnVisible(sackBtn, false);
    setBtnVisible(renewBtn, false);
    return;
  }

  const pendingRenewal = Boolean(data.pending_owner_renewal);
  const dealRecord = formatDealRecord(data);
  const targetProgress = formatTargetProgress(data);
  const currentPos =
    data.season_position != null ? formatOrdinal(data.season_position) : "—";

  if (statusEl) {
    statusEl.innerHTML = `
      <dl style="display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:0;font-size:14px;">
        <dt>Manager</dt><dd><b>${data.manager_name}</b> (rating ${data.manager_rating})</dd>
        <dt>Market value</dt><dd>${formatMoney(Number(data.market_value || 0))}</dd>
        <dt>Contract</dt><dd>${
          pendingRenewal
            ? "Deal complete — renew to keep them"
            : `${data.contract_seasons_remaining ?? 0} season(s) remaining`
        }</dd>
        <dt>Weekly wage</dt><dd>${formatMoney(Number(data.weekly_wage || 0))}</dd>
        <dt>Division</dt><dd>${formatDivisionLabel(data.division)}</dd>
        <dt>League position</dt><dd>${currentPos}</dd>
        <dt>Target</dt><dd>${formatManagerTarget(data)}</dd>
        <dt>On target?</dt><dd><span class="${targetProgress.className}">${targetProgress.text}</span></dd>
        ${dealRecord ? `<dt>Deal record</dt><dd>${dealRecord}</dd>` : ""}
        ${formatChartBands(data) ? `<dt>Impact chart</dt><dd>${formatChartBands(data)}</dd>` : ""}
        <dt>Sack allowance</dt><dd>${data.manager_sacks_remaining ? "Available this season" : "Used"}</dd>
      </dl>
      ${
        pendingRenewal
          ? `<p class="expectation-note" style="margin-top:10px;">They hit their target in at least one season of the deal. Renew for another 2 seasons.</p>`
          : `<p class="expectation-note" style="margin-top:10px;">On target uses the live league table vs their deal target for this season. Final hit/miss is locked when you run Process manager contracts.</p>`
      }
    `;
  }

  const januaryWindow = await isGpslJanuary();

  setBtnVisible(renewBtn, pendingRenewal);
  setBtnVisible(listBtn, januaryWindow && !pendingRenewal);
  setBtnVisible(
    sackBtn,
    januaryWindow && !pendingRenewal && Boolean(data.manager_sacks_remaining)
  );

  if (listBtn) listBtn.dataset.managerId = String(data.manager_id);
  if (sackBtn) {
    sackBtn.dataset.clubShort = clubShortName;
    sackBtn.disabled = !data.manager_sacks_remaining;
  }

  if (hintEl) {
    if (pendingRenewal) {
      hintEl.textContent = "Renewal available — also shown on Squad.";
    } else if (!januaryWindow) {
      hintEl.textContent =
        "List for transfer and sack are available in January only.";
    } else {
      hintEl.textContent = "";
    }
  }
}

function renderSubsidyGrid(preview, loadError) {
  const grid = document.getElementById("subsidyGrid");
  if (!grid) return;

  if (loadError) {
    grid.innerHTML = `<p class="subsidy-meta">${loadError}</p>`;
    return;
  }

  if (!preview) {
    grid.innerHTML = '<p class="subsidy-meta">Subsidy preview unavailable.</p>';
    return;
  }

  const hg = preview.homegrown || {};
  const youth = preview.youth || {};
  const bnb = preview.bnb || {};
  const statusOrDash = (s) => (s && s !== "—" ? s : "No tier");

  grid.innerHTML = `
    <div class="subsidy-card">
      <h3>Homegrown (HG)</h3>
      <p class="subsidy-status">${statusOrDash(hg.status)}</p>
      <p class="subsidy-meta">${hg.count ?? 0} homegrown player${hg.count === 1 ? "" : "s"} in squad</p>
      <p class="subsidy-amount">Est. payout ${formatMoney(Number(hg.amount || 0))}</p>
    </div>
    <div class="subsidy-card">
      <h3>Youth</h3>
      <p class="subsidy-status">${statusOrDash(youth.status)}</p>
      <p class="subsidy-meta">${youth.count ?? 0} under-21 player${youth.count === 1 ? "" : "s"} in squad</p>
      <p class="subsidy-amount">Est. payout ${formatMoney(Number(youth.amount || 0))}</p>
    </div>
    <div class="subsidy-card">
      <h3>Weak squad bonus</h3>
      <p class="subsidy-status">${statusOrDash(bnb.status)}</p>
      <p class="subsidy-meta">${bnb.count ?? 0} of ${bnb.min_required ?? 14} at rating ≤${bnb.max_rating ?? 72} · ${formatMoney(Number(bnb.flat_bonus ?? 10000000))} bonus when qualified</p>
      <p class="subsidy-amount">Est. payout ${formatMoney(Number(bnb.amount || 0))}</p>
    </div>
  `;
}

async function loadSubsidyStatus(clubShortName) {
  const { data, error } = await supabase.rpc("gov_subsidy_club_preview", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("gov_subsidy_club_preview") || msg.includes("function")) {
      renderSubsidyGrid(
        null,
        "Run supabase/sql/government_subsidies.sql in Supabase to enable subsidy status."
      );
      return;
    }
    renderSubsidyGrid(null, msg || "Could not load subsidy status.");
    return;
  }

  renderSubsidyGrid(data, null);
}

async function loadChallengeProgress(clubShortName) {
  const { data, error } = await supabase.rpc("competition_challenge_club_progress", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("competition_challenge_club_progress") || msg.includes("function")) {
      renderChallengeGrid(
        null,
        "Run supabase/sql/competition_challenges.sql to enable challenge tracking."
      );
      return;
    }
    renderChallengeGrid(null, msg || "Could not load challenges.");
    return;
  }

  renderChallengeGrid(data, null);
}

function wireChallengeExpandToggle() {
  const btn = document.getElementById("toggleChallengesBtn");
  const panel = document.getElementById("challengeExpand");
  btn?.addEventListener("click", () => {
    if (!panel) return;
    const show = panel.hidden;
    panel.hidden = !show;
    btn.setAttribute("aria-expanded", show ? "true" : "false");
  });
}

async function initClubDetailsPage() {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club, error } = await loadOwnerClub(user.id);

  if (error) {
    console.error("Club Details club load:", error);
    showLoadError(
      `Could not load club details (${error.message}). Check Supabase Clubs access.`
    );
    return;
  }

  if (!club?.ShortName) {
    showLoadError(
      "No club is linked to your account. Ask an admin to link your club under Owner administration."
    );
    return;
  }

  const clubNameEl = document.getElementById("clubName");
  const displayName = fullClubName(club.ShortName) || club.Club || club.ShortName;
  setClubDetailLink(clubNameEl, clubPageHref(club.ShortName), displayName);
  document.getElementById("shortName").textContent = club.ShortName;
  setClubDetailLink(
    document.getElementById("stadiumName"),
    "stadium.html",
    club.Stadium || "—"
  );
  document.getElementById("stadiumCapacity").textContent =
    club.Capacity != null && club.Capacity !== ""
      ? String(club.Capacity)
      : "—";
  const nationLabel = club.Nation ? formatNationLabel(club.Nation) : "—";
  setClubDetailLink(
    document.getElementById("clubNation"),
    club.Nation ? gpdbNationHref(club.Nation) : null,
    nationLabel
  );

  const divEl = document.getElementById("compDivision");
  try {
    const season = await loadCurrentSeason(supabase);
    if (season) {
      const regs = await loadActiveSeasonRegistrations(supabase);
      renderDivisionCell(divEl, divisionSlugForClub(regs, club.ShortName));
    } else {
      divEl.textContent = "No active season";
    }
  } catch (err) {
    console.warn("Club Details division:", err);
    divEl.textContent = "—";
  }

  pageClubShort = club.ShortName;

  await loadChallengeProgress(club.ShortName);
  await Promise.all([
    loadExpectationSection(club.ShortName),
    loadManagerSection(club.ShortName),
    loadKitsSection(club.ShortName),
    loadDashboardThemeSection(club.ShortName),
  ]);
  await loadSubsidyStatus(club.ShortName);

  wireChallengeExpandToggle();
  wireManagerActions();
}

async function loadKitsSection(clubShort) {
  const el = document.getElementById("clubKitsContent");
  if (!el) return;

  try {
    const kitRow = await loadClubKits(supabase, clubShort);
    cachedKitRow = kitRow;
    el.innerHTML = renderKitsPanelHtml(clubShort, kitRow);
  } catch (err) {
    console.warn("Club Details kits:", err);
    el.textContent = "Could not load kit images.";
  }
}

function themeFieldIds() {
  return [
    ["themePrimaryPicker", "themePrimaryHex", "color_primary"],
    ["themeTextPicker", "themeTextHex", "color_text"],
    ["themeSecondaryPicker", "themeSecondaryHex", "color_secondary"],
    ["themeBorderPicker", "themeBorderHex", "color_border"],
  ];
}

function readThemeScopeFromForm() {
  const clubPages = document.getElementById("themeScopeClubPages");
  if (clubPages?.checked) return THEME_SCOPES.clubPages;
  return THEME_SCOPES.dashboard;
}

function readThemeDraftFromForm() {
  const enabledEl = document.getElementById("themeEnabled");
  const draft = { ...themeDraft };
  draft.enabled = enabledEl?.checked === true;
  draft.theme_scope = readThemeScopeFromForm();

  for (const [pickerId, hexId, key] of themeFieldIds()) {
    const hexEl = document.getElementById(hexId);
    const pickerEl = document.getElementById(pickerId);
    const fromHex = normalizeHexColor(hexEl?.value);
    const fromPicker = normalizeHexColor(pickerEl?.value);
    draft[key] = fromHex || fromPicker || GPSL_THEME_DEFAULTS[key];
  }

  return draft;
}

function syncThemeToggleHint() {
  const row = document.querySelector(".theme-toggle-row--prominent");
  const enabled = document.getElementById("themeEnabled")?.checked === true;
  if (row) row.classList.toggle("theme-toggle-row--off", !enabled);
}

function syncThemeScopeUi() {
  const enabled = document.getElementById("themeEnabled")?.checked === true;
  const fieldset = document.getElementById("themeScopeFieldset");
  if (fieldset) fieldset.disabled = !enabled;
}

function writeThemeDraftToForm(theme) {
  themeDraft = normalizeThemeRow(theme);
  const enabledEl = document.getElementById("themeEnabled");
  if (enabledEl) enabledEl.checked = themeDraft.enabled === true;

  const scope = normalizeThemeScope(themeDraft.theme_scope);
  const dashRadio = document.getElementById("themeScopeDashboard");
  const clubRadio = document.getElementById("themeScopeClubPages");
  if (dashRadio) dashRadio.checked = scope === THEME_SCOPES.dashboard;
  if (clubRadio) clubRadio.checked = scope === THEME_SCOPES.clubPages;

  for (const [pickerId, hexId, key] of themeFieldIds()) {
    const pickerEl = document.getElementById(pickerId);
    const hexEl = document.getElementById(hexId);
    const value = themeDraft[key] || GPSL_THEME_DEFAULTS[key];
    if (pickerEl) pickerEl.value = value;
    if (hexEl) hexEl.value = value;
  }

  const preview = document.getElementById("themePreview");
  if (preview) {
    preview.innerHTML = renderThemePreviewHtml(themeDraft);
  }

  syncThemeToggleHint();
  syncThemeScopeUi();
  applyClubDashboardTheme(themeDraft, { pageKey: "club_details" });
}

function setThemeStatus(message, kind = "") {
  const el = document.getElementById("themeStatus");
  if (!el) return;
  el.textContent = message || "";
  el.classList.remove("theme-status--ok", "theme-status--err");
  if (kind === "ok") el.classList.add("theme-status--ok");
  if (kind === "err") el.classList.add("theme-status--err");
}

function wireDashboardThemePanel(clubShort) {
  if (document.getElementById("clubThemePanel")?.dataset.wired === "1") return;
  const panel = document.getElementById("clubThemePanel");
  if (!panel) return;
  panel.dataset.wired = "1";

  for (const [pickerId, hexId] of themeFieldIds()) {
    const pickerEl = document.getElementById(pickerId);
    const hexEl = document.getElementById(hexId);
    if (!pickerEl || !hexEl) continue;

    pickerEl.addEventListener("input", () => {
      hexEl.value = pickerEl.value;
      themeDraft = readThemeDraftFromForm();
      themeDraft.source_kit = "manual";
      writeThemeDraftToForm(themeDraft);
    });

    hexEl.addEventListener("change", () => {
      const normalized = normalizeHexColor(hexEl.value);
      if (!normalized) {
        hexEl.value = pickerEl.value;
        return;
      }
      hexEl.value = normalized;
      pickerEl.value = normalized;
      themeDraft = readThemeDraftFromForm();
      themeDraft.source_kit = "manual";
      writeThemeDraftToForm(themeDraft);
    });
  }

  const enabledEl = document.getElementById("themeEnabled");
  enabledEl?.addEventListener("change", () => {
    themeDraft = readThemeDraftFromForm();
    writeThemeDraftToForm(themeDraft);
  });

  for (const id of ["themeScopeDashboard", "themeScopeClubPages"]) {
    document.getElementById(id)?.addEventListener("change", () => {
      themeDraft = readThemeDraftFromForm();
      writeThemeDraftToForm(themeDraft);
    });
  }

  document.getElementById("themeSuggestBtn")?.addEventListener("click", async () => {
    const btn = document.getElementById("themeSuggestBtn");
    const kind = document.getElementById("themeKitSource")?.value || "home";
    if (btn) btn.disabled = true;
    setThemeStatus("Sampling kit colours…");
    try {
      const suggested = await suggestThemeFromKit(clubShort, cachedKitRow, kind);
      themeDraft = {
        ...suggested,
        enabled: readThemeDraftFromForm().enabled,
        theme_scope: readThemeDraftFromForm().theme_scope,
        source_kit: kind,
      };
      writeThemeDraftToForm(themeDraft);
      setThemeStatus(
        suggested.sample_note ||
          `Suggested from ${kind} kit — adjust if needed, then save.`,
        "ok"
      );
    } catch (err) {
      console.warn("Theme suggest:", err);
      setThemeStatus(err?.message || "Could not read colours from kit image.", "err");
    } finally {
      if (btn) btn.disabled = false;
    }
  });

  document.getElementById("themeResetBtn")?.addEventListener("click", () => {
    themeDraft = {
      ...GPSL_THEME_DEFAULTS,
      enabled: readThemeDraftFromForm().enabled,
      theme_scope: readThemeDraftFromForm().theme_scope,
      source_kit: "manual",
    };
    writeThemeDraftToForm(themeDraft);
    setThemeStatus("Reset to GPSL defaults (not saved yet).");
  });

  document.getElementById("themeSaveBtn")?.addEventListener("click", async () => {
    const btn = document.getElementById("themeSaveBtn");
    themeDraft = readThemeDraftFromForm();
    themeDraft.enabled = true;
    writeThemeDraftToForm(themeDraft);
    if (btn) btn.disabled = true;
    setThemeStatus("Saving…");
    try {
      await saveClubDashboardTheme(supabase, themeDraft);
      const scopeLabel =
        normalizeThemeScope(themeDraft.theme_scope) === THEME_SCOPES.clubPages
          ? "Dashboard and club pages"
          : "Dashboard only";
      setThemeStatus(`Club colours saved and applied (${scopeLabel}).`, "ok");
    } catch (err) {
      console.warn("Theme save:", err);
      const msg = String(err?.message || err);
      if (msg.includes("club_owner_dashboard_theme_save") || msg.includes("function")) {
        setThemeStatus(
          "Could not save — run supabase/sql/patches/club_dashboard_theme_scope.sql in Supabase.",
          "err"
        );
      } else if (
        msg.includes("color_text") ||
        msg.includes("theme_scope") ||
        msg.includes("column")
      ) {
        setThemeStatus(
          "Could not save — run supabase/sql/patches/club_dashboard_theme_scope.sql in Supabase.",
          "err"
        );
      } else {
        setThemeStatus(msg, "err");
      }
    } finally {
      if (btn) btn.disabled = false;
    }
  });
}

async function loadDashboardThemeSection(clubShort) {
  const panel = document.getElementById("clubThemePanel");
  if (!panel) return;

  if (!cachedKitRow) {
    try {
      cachedKitRow = await loadClubKits(supabase, clubShort);
    } catch (err) {
      console.warn("Club Details kits for theme:", err);
    }
  }

  try {
    const saved = await loadClubDashboardTheme(supabase, clubShort);
    writeThemeDraftToForm(saved);
    wireDashboardThemePanel(clubShort);
    if (saved.enabled !== true) {
      const hasCustom =
        saved.color_primary !== GPSL_THEME_DEFAULTS.color_primary ||
        saved.color_secondary !== GPSL_THEME_DEFAULTS.color_secondary ||
        saved.color_border !== GPSL_THEME_DEFAULTS.color_border;
      if (hasCustom) {
        setThemeStatus(
          "Colours saved but not active — tick the box above or click Save again to apply.",
          "err"
        );
      }
    }
  } catch (err) {
    console.warn("Club Details dashboard theme:", err);
    writeThemeDraftToForm(GPSL_THEME_DEFAULTS);
    wireDashboardThemePanel(clubShort);
    setThemeStatus(
      "Theme settings unavailable — run supabase/sql/patches/club_dashboard_theme.sql in Supabase.",
      "err"
    );
  }
}

async function renewManagerContract(hintEl) {
  const { error } = await supabase.rpc("manager_owner_renew");
  if (error) {
    if (hintEl) hintEl.textContent = error.message;
    return false;
  }
  if (hintEl) hintEl.textContent = "Manager renewed for 2 seasons.";
  return true;
}

function wireManagerActions() {
  const listBtn = document.getElementById("listManagerBtn");
  const sackBtn = document.getElementById("sackManagerBtn");
  const renewBtn = document.getElementById("renewManagerBtn");
  const hintEl = document.getElementById("managerHint");

  if (renewBtn && !renewBtn.dataset.wired) {
    renewBtn.dataset.wired = "1";
    renewBtn.addEventListener("click", async () => {
      if (!confirm("Renew manager for another 2-season deal?")) return;
      renewBtn.disabled = true;
      const ok = await renewManagerContract(hintEl);
      renewBtn.disabled = false;
      if (ok && pageClubShort) {
        await Promise.all([
          loadExpectationSection(pageClubShort),
          loadManagerSection(pageClubShort),
        ]);
      }
    });
  }

  if (listBtn && !listBtn.dataset.wired) {
    listBtn.dataset.wired = "1";
    listBtn.addEventListener("click", async () => {
      const managerId = Number(listBtn.dataset.managerId);
      if (!managerId) return;
      listBtn.disabled = true;
      const { error } = await supabase.rpc("manager_list_for_transfer", {
        p_manager_id: managerId,
      });
      listBtn.disabled = false;
      if (error) {
        if (hintEl) hintEl.textContent = error.message;
        return;
      }
      if (hintEl) hintEl.textContent = "Manager listed — see Manager Transfer Market.";
      if (pageClubShort) await refreshNavClubListingState(pageClubShort);
      refreshNavListingIndicators();
    });
  }

  if (sackBtn && !sackBtn.dataset.wired) {
    sackBtn.dataset.wired = "1";
    sackBtn.addEventListener("click", async () => {
      if (
        !confirm(
          "Sack manager? You receive half market value, cannot sack again this season, and cannot re-sign this manager until next season."
        )
      ) {
        return;
      }
      const short = sackBtn.dataset.clubShort;
      sackBtn.disabled = true;
      const { error } = await supabase.rpc("manager_sack");
      sackBtn.disabled = false;
      if (error) {
        if (hintEl) hintEl.textContent = error.message;
        return;
      }
      if (hintEl) {
        hintEl.textContent =
          "Manager sacked. You cannot re-sign them until next season.";
      }
      if (short) {
        await Promise.all([
          loadExpectationSection(short),
          loadManagerSection(short),
        ]);
      }
    });
  }
}

document.addEventListener("DOMContentLoaded", () => {
  initClubDetailsPage().catch((err) => {
    console.error("Club Details init failed:", err);
    showLoadError(
      err?.message ||
        "Club Details failed to load. Try a hard refresh (Ctrl+F5)."
    );
  });
});
