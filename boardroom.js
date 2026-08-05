/**
 * Boardroom — club expectations + manager deal (moved from Club Details).
 */
import {
  supabase,
  initGlobal,
  refreshNavClubListingState,
  refreshNavListingIndicators,
} from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";
import { loadCalendarStatus } from "./competition_calendar.js";
import { renderBoardroomIntro } from "./boardroom_rules.js";

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
      text: `Deal complete — renewal available (${hits} target hit${hits === 1 ? "" : "s"})`,
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

function renderHeroStats({ clubLabel, tier, managerName }) {
  const el = document.getElementById("heroStats");
  if (!el) return;
  el.innerHTML = `
    <div class="board-stat">
      <div class="label">Club</div>
      <div class="value">${clubLabel || "—"}</div>
    </div>
    <div class="board-stat">
      <div class="label">Tier</div>
      <div class="value">${tier || "—"}</div>
    </div>
    <div class="board-stat">
      <div class="label">Manager</div>
      <div class="value">${managerName || "Vacant"}</div>
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
          ? `<p class="expectation-note">They hit their target in at least one season of the deal. Renew for another 2 seasons.</p>`
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
      hintEl.textContent = "Renewal available — also shown on Squad.";
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
      if (!confirm("Renew manager for another 2-season deal?")) return;
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
  const tagline = document.getElementById("boardTagline");
  if (tagline) {
    tagline.textContent = `${clubLabel} — expectations & manager deal`;
  }

  wireManagerActions();

  const [fill, mgr] = await Promise.all([
    loadExpectationSection(club.ShortName),
    loadManagerSection(club.ShortName),
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
