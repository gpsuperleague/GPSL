/**
 * Boardroom — club expectations + manager deal (moved from Club Details).
 */
import {
  supabase,
  initGlobal,
  refreshNavClubListingState,
  refreshNavListingIndicators,
} from "./global.js";
import { initGpslInfoTips, tipAttrs } from "./gpsl_info_tips.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney, loadClubLoans, leagueBadgeHtml } from "./competition.js";
import { loadCalendarStatus } from "./competition_calendar.js";
import { loadClubWageBillSummary } from "./club_wage_bill.js";
import { computeAdvisoryTransferBudget } from "./finance_advisory_budget.js";
import {
  loadFinanceSeasonContext,
  resolveFinanceSeasonView,
} from "./finance_page_common.js";
import {
  computeBoardFinanceRating,
  renderBoardroomIntro,
} from "./boardroom_rules.js";
import { loadSeasonPositionChart } from "./club_season_position_chart.js";

let pageClubShort = null;

function setBtnVisible(btn, visible) {
  if (!btn) return;
  btn.classList.toggle("is-hidden", !visible);
}

function showLoadError(message) {
  const el = document.getElementById("boardError");
  if (el) {
    el.textContent = message;
    el.hidden = false;
  }
}

function formatDivisionLabel(division) {
  if (division === "super_league") return "Super League";
  if (division === "championship_a") return "Championship A";
  if (division === "championship_b") return "Championship B";
  return division || "—";
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

function formatTargetProgress(row) {
  const pos = row?.season_position;
  const posLabel = pos != null ? ` (currently ${formatOrdinal(pos)})` : "";

  if (row?.pending_owner_renewal) {
    const hits = Number(row.deal_target_hits) || 0;
    return {
      text: `Deal complete — renew before August (${hits} target hit${hits === 1 ? "" : "s"})`,
      className: "manager-target--on",
    };
  }

  if (row?.target_met === true) {
    return { text: `On target${posLabel}`, className: "manager-target--on" };
  }
  if (row?.target_met === false) {
    return { text: `Off target${posLabel}`, className: "manager-target--off" };
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

function formatDealRecord(data) {
  const hits = Number(data?.deal_target_hits);
  const misses = Number(data?.deal_target_misses);
  if (!Number.isFinite(hits) && !Number.isFinite(misses)) return null;
  const h = Number.isFinite(hits) ? hits : 0;
  const m = Number.isFinite(misses) ? misses : 0;
  if (h + m <= 0) return "No completed seasons on this deal yet";
  return `${h} hit · ${m} miss (this deal)`;
}

function escapeXml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Fit club name onto the boardroom crest plaque. */
function setBoardCrestName(clubLabel) {
  const textEl = document.getElementById("boardCrestName");
  const plate = document.getElementById("boardCrestPlate");
  if (!textEl) return;

  const name = String(clubLabel || "Club").trim() || "Club";
  const label = `${name} Boardroom`;
  const len = label.length;
  let fontSize = 13;
  if (len > 28) fontSize = 8;
  else if (len > 22) fontSize = 9;
  else if (len > 18) fontSize = 11;
  else if (len > 14) fontSize = 12;

  if (plate) {
    if (len > 24) {
      plate.setAttribute("x", "55");
      plate.setAttribute("width", "290");
    } else if (len > 18) {
      plate.setAttribute("x", "70");
      plate.setAttribute("width", "260");
    } else if (len > 12) {
      plate.setAttribute("x", "90");
      plate.setAttribute("width", "220");
    } else {
      plate.setAttribute("x", "110");
      plate.setAttribute("width", "180");
    }
  }

  textEl.setAttribute("font-size", String(fontSize));
  textEl.textContent = label;
}

function renderHeroStats({ clubLabel, tier, managerName }) {
  setBoardCrestName(clubLabel);
  const el = document.getElementById("heroStats");
  if (!el) return;
  el.innerHTML = `
    <div class="board-stat">
      <div class="label">Club</div>
      <div class="value">${escapeXml(clubLabel) || "—"}</div>
    </div>
    <div class="board-stat">
      <div class="label">Tier</div>
      <div class="value">${escapeXml(tier) || "—"}</div>
    </div>
    <div class="board-stat">
      <div class="label">Manager</div>
      <div class="value">${escapeXml(managerName) || "Vacant"}</div>
    </div>
  `;
}

async function loadExpectationSection(clubShortName) {
  const statusEl = document.getElementById("expectationStatus");
  if (!statusEl) return null;

  const { data, error } = await supabase.rpc("competition_compute_stadium_fill", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    statusEl.textContent = msg.includes("competition_compute_stadium_fill")
      ? "Run stadium_attendance_v2.sql to enable expectations."
      : msg;
    return null;
  }

  if (!data || data.error) {
    statusEl.textContent = data?.error || "Expectation data unavailable.";
    return null;
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
      <p class="expectation-note">Checked at season archive. See <a href="learning_gpsl.html#club-expectations">Learning GPSL</a> and <a href="stadium.html">Stadium</a> for full rules.</p>
    </div>
  `;

  return data;
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

function moneyClass(n) {
  const v = Number(n) || 0;
  if (v > 0.5) return "positive";
  if (v < -0.5) return "negative";
  return "muted";
}

function renderBoardFinanceSection({
  balance,
  wages,
  transferBudget,
  projected,
  loansOutstanding,
  loanCount,
  advisory,
}) {
  const grid = document.getElementById("boardFinanceGrid");
  const ratingEl = document.getElementById("boardFinanceRating");
  if (!grid) return;

  const wageHint =
    wages?.players != null
      ? `Players ${formatMoney(wages.players)} · Manager ${formatMoney(wages.manager)}`
      : "";
  const transferHint = advisory?.runwayNegative
    ? `Runway ${formatMoney(advisory.raw)} — spend shown as ₿0`
    : advisory?.bidExposure > 0.5
      ? `${advisory.bidCount} winning bid${advisory.bidCount === 1 ? "" : "s"} (−${formatMoney(advisory.bidExposure)})`
      : "Ops forecast excl. transfers";
  const loanHint =
    loanCount > 0
      ? `${loanCount} open loan${loanCount === 1 ? "" : "s"}`
      : "No open Central Bank loans";

  grid.innerHTML = `
    <a class="board-finance-stat" href="finances.html">
      <div class="label">Balance</div>
      <div class="value ${moneyClass(balance)}">${formatMoney(balance)}</div>
      <span class="hint">Current spendable cash →</span>
    </a>
    <a class="board-finance-stat" href="finances.html">
      <div class="label">Wage bill</div>
      <div class="value muted">${formatMoney(wages?.total ?? 0)}</div>
      <span class="hint">${wageHint || "Seasonal players + manager"} →</span>
    </a>
    <a class="board-finance-stat" href="transfer_center.html">
      <div class="label">Transfer budget</div>
      <div class="value ${moneyClass(transferBudget)}">${formatMoney(transferBudget)}</div>
      <span class="hint">${transferHint} →</span>
    </a>
    <a class="board-finance-stat" href="finances_accounts.html">
      <div class="label">Projected EOS</div>
      <div class="value ${moneyClass(projected)}">${formatMoney(projected)}</div>
      <span class="hint">Balance + pending forecasts →</span>
    </a>
    <a class="board-finance-stat" href="central_bank_counter.html">
      <div class="label">Loans</div>
      <div class="value ${loansOutstanding > 0.5 ? "negative" : "muted"}">${formatMoney(loansOutstanding)}</div>
      <span class="hint">${loanHint} →</span>
    </a>
  `;

  const rating = computeBoardFinanceRating({
    balance,
    projected,
    wages: wages?.total ?? 0,
    loansOutstanding,
    transferBudget,
  });

  if (ratingEl) {
    ratingEl.hidden = false;
    ratingEl.innerHTML = `
      <div${tipAttrs(`Board finance rating ${rating.grade} — score ${rating.score}/100. Based on balance, projected end-of-season, wages, and loans.`, `board-rating-grade ${rating.className}`)}>${rating.grade}</div>
      <div class="board-rating-copy">
        <p class="title">Board finance rating — ${rating.label}</p>
        <p class="detail">${rating.detail}</p>
      </div>
    `;
  }

  return rating;
}

async function loadBoardFinanceSection(clubShortName) {
  const grid = document.getElementById("boardFinanceGrid");
  try {
    const seasonView = await resolveFinanceSeasonView(supabase, clubShortName);
    const [data, wageBill, loans] = await Promise.all([
      loadFinanceSeasonContext(supabase, clubShortName, { seasonView }),
      loadClubWageBillSummary(supabase, clubShortName).catch((err) => {
        console.warn("boardroom wage bill:", err);
        return { players: 0, manager: 0, total: 0 };
      }),
      loadClubLoans(supabase).catch((err) => {
        console.warn("boardroom loans:", err);
        return [];
      }),
    ]);

    if (data?.missingArchive) {
      if (grid) grid.innerHTML = `<p class="board-meta">Finance snapshot unavailable.</p>`;
      return null;
    }

    const openLoans = (loans || []).filter(
      (l) => Number(l.outstanding_principal || 0) > 0.5
    );
    const loansOutstanding = openLoans.reduce(
      (s, l) => s + Number(l.outstanding_principal || 0),
      0
    );

    let advisory = null;
    try {
      advisory = await computeAdvisoryTransferBudget(supabase, clubShortName, {
        balanceNow: data.balanceNow,
        byLine: data.byLine,
        pendingByLine: data.pendingByLine,
        bidExposure: data.bidExposure,
      });
    } catch (err) {
      console.warn("boardroom advisory budget:", err);
    }

    return renderBoardFinanceSection({
      balance: data.balanceNow,
      wages: wageBill,
      transferBudget: advisory?.spendable ?? 0,
      projected: data.projectedBalance,
      loansOutstanding,
      loanCount: openLoans.length,
      advisory,
    });
  } catch (err) {
    console.warn("boardroom finances:", err);
    if (grid) {
      grid.innerHTML = `<p class="board-meta">${escapeXml(err.message || "Could not load finances.")}</p>`;
    }
    return null;
  }
}

async function isManagerListSackWindow() {
  try {
    const { data, error } = await supabase.rpc("manager_list_sack_window_open");
    if (!error && data != null) return Boolean(data);
  } catch (_) {
    /* fall through */
  }
  const status = await loadCalendarStatus(supabase);
  if (!status?.calendar_configured) return false;
  const m = String(status.active_gpsl_month || "").toLowerCase();
  return ["june", "july", "january"].includes(m);
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
    return null;
  }

  if (!data?.manager_id) {
    if (statusEl) {
      statusEl.innerHTML =
        'No manager signed. <a href="MGDB.html">Browse MGDB</a> or the manager transfer market.';
    }
    setBtnVisible(listBtn, false);
    setBtnVisible(sackBtn, false);
    setBtnVisible(renewBtn, false);
    return null;
  }

  const pendingRenewal = Boolean(data.pending_owner_renewal);
  const dealRecord = formatDealRecord(data);
  const targetProgress = formatTargetProgress(data);
  const currentPos =
    data.season_position != null ? formatOrdinal(data.season_position) : "—";

  if (statusEl) {
    statusEl.innerHTML = `
      <dl class="expectation-dl">
        <dt>Manager</dt><dd><b>${data.manager_name}</b> (rating ${data.manager_rating})</dd>
        <dt>Market value</dt><dd>${formatMoney(Number(data.market_value || 0))}</dd>
        <dt>Contract</dt><dd>${
          pendingRenewal
            ? "Deal complete — renew before August to keep them"
            : `${data.contract_seasons_remaining ?? 0} season(s) remaining`
        }</dd>
        <dt>Weekly wage</dt><dd>${formatMoney(Number(data.weekly_wage || 0))}</dd>
        <dt>Division</dt><dd>${leagueBadgeHtml(data.division, { size: "sm" })}${formatDivisionLabel(data.division)}</dd>
        <dt>League position</dt><dd>${currentPos}</dd>
        <dt>Target</dt><dd>${formatManagerTarget(data)}</dd>
        <dt>On target?</dt><dd><span class="${targetProgress.className}">${targetProgress.text}</span></dd>
        ${dealRecord ? `<dt>Deal record</dt><dd>${dealRecord}</dd>` : ""}
        ${formatChartBands(data) ? `<dt>Impact chart</dt><dd>${formatChartBands(data)}</dd>` : ""}
        <dt>Sack allowance</dt><dd>${data.manager_sacks_remaining ? "Available this season" : "Used"}</dd>
      </dl>
      ${
        pendingRenewal
          ? `<p class="expectation-note">They hit their target in at least one season of the deal. Renew in June or July for another 2 seasons — if not renewed before August starts, they are released for market value.</p>`
          : `<p class="expectation-note">On target uses the live league table vs their deal target for this season. Final hit/miss is locked when you run Process manager contracts.</p>`
      }
    `;
  }

  const januaryWindow = await isManagerListSackWindow();

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
      hintEl.textContent =
        "Renewal available in June/July only (also on Squad). Must be done before August or they leave for market value.";
    } else if (!januaryWindow) {
      hintEl.textContent =
        "List for transfer and sack are available in June, July, and January (not August).";
    } else {
      hintEl.textContent =
        "Sack: not until mid-season of this spell (summer signing → January; January signing → next June–July).";
    }
  }

  return data;
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
      if (
        !confirm(
          "Renew manager for another 2-season deal?\n\nIf not renewed before August starts they are released for market value."
        )
      ) {
        return;
      }
      renewBtn.disabled = true;
      const ok = await renewManagerContract(hintEl);
      renewBtn.disabled = false;
      if (ok && pageClubShort) {
        const [fill, mgr] = await Promise.all([
          loadExpectationSection(pageClubShort),
          loadManagerSection(pageClubShort),
        ]);
        renderHeroStats({
          clubLabel: fullClubName(pageClubShort) || pageClubShort,
          tier: formatClubTierLabel(fill?.club_tier),
          managerName: mgr?.manager_name,
        });
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
        const [fill, mgr] = await Promise.all([
          loadExpectationSection(short),
          loadManagerSection(short),
        ]);
        renderHeroStats({
          clubLabel: fullClubName(short) || short,
          tier: formatClubTierLabel(fill?.club_tier),
          managerName: mgr?.manager_name,
        });
      }
    });
  }
}

async function initBoardroom() {
  initGpslInfoTips();
  renderBoardroomIntro();
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (error) {
    showLoadError(`Could not load club (${error.message}).`);
    return;
  }

  if (!club?.ShortName) {
    showLoadError(
      "No club is linked to your account. Ask an admin to link your club under Owner administration."
    );
    return;
  }

  pageClubShort = club.ShortName;
  const clubLabel = fullClubName(club.ShortName) || club.Club || club.ShortName;
  setBoardCrestName(clubLabel);
  const title = document.getElementById("boardTitle");
  if (title) title.textContent = `${clubLabel} Boardroom`;
  const tagline = document.getElementById("boardTagline");
  if (tagline) {
    tagline.textContent = `Finances · expectations · manager deal · subsidies · analysis`;
  }

  wireManagerActions();

  const [fill, mgr] = await Promise.all([
    loadExpectationSection(club.ShortName),
    loadManagerSection(club.ShortName),
    loadSubsidyStatus(club.ShortName),
    loadBoardFinanceSection(club.ShortName),
    loadSeasonPositionChart(supabase, club.ShortName, { maxSeasons: 2 }),
  ]);

  renderHeroStats({
    clubLabel,
    tier: formatClubTierLabel(fill?.club_tier),
    managerName: mgr?.manager_name,
  });
}

document.addEventListener("DOMContentLoaded", () => {
  initBoardroom().catch((err) => {
    console.error("Boardroom init failed:", err);
    showLoadError(
      err?.message || "Boardroom failed to load. Try a hard refresh (Ctrl+F5)."
    );
  });
});
