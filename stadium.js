import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { stadiumImageUrl } from "./stadium_images.js";
import {
  formatMoney,
  loadLeagueFixtures,
  estimateGateForClub,
  loadClubSeasonArchive,
  loadStandings,
  DIVISION_LABELS,
} from "./competition.js";
import {
  loadStadiumExpansionStatus,
  loadStadiumExpansionQuotes,
  createStadiumQuote,
  placeStadiumOrder,
  cancelPreBuildOrder,
  day7StadiumDecision,
  cancelBuildOrder,
  formatQuoteLabel,
  expansionBlockedReason,
  renderBuildStatusHtml,
} from "./stadium_expansion.js";
let clubShortName = null;

function renderStadiumPhoto(shortName, stadiumName) {
  const slot = document.getElementById("stadiumPhotoSlot");
  if (!slot) return;

  const src = stadiumImageUrl(shortName);
  const img = new Image();
  img.onload = () => {
    slot.innerHTML = `
      <div class="stadium-photo-wrap">
        <img class="stadium-photo" src="${src}" alt="${stadiumName || "Stadium"}">
        <span class="stadium-photo-credit">StadiumDB</span>
      </div>
    `;
  };
  img.onerror = () => {
    slot.innerHTML = `
      <p class="stadium-photo-missing">
        No stadium photo yet. Run <code>node scripts/fetch_stadium_images.mjs</code> locally.
      </p>
    `;
  };
  img.src = src;
}

function renderGateBreakdown(data) {
  const el = document.getElementById("gateBreakdown");
  if (!el) return;

  if (!data) {
    el.innerHTML =
      '<p class="empty">Could not estimate gate — check active season and SQL phase 5.</p>';
    return;
  }

  const fillPct = ((Number(data.attendance_rate) || 0) * 100).toFixed(1);
  const legacy = data.legacy_fallback;

  if (legacy) {
    el.innerHTML = `
      <dl class="breakdown">
        <dt>Stadium capacity</dt><dd>${Number(data.capacity || 0).toLocaleString("en-GB")}</dd>
        <dt>League position</dt><dd>${data.table_position ?? "—"}</dd>
        <dt>5-season avg finish</dt><dd>${data.history_avg_position ?? "10 (neutral)"}</dd>
        <dt>Fill rate</dt><dd>${fillPct}%</dd>
        <dt>Est. gate per home match</dt><dd class="highlight">${formatMoney(data.total_gate)}</dd>
      </dl>
      <p class="note">Legacy gate formula — run <code>competition_club_stadium_attendance.sql</code> for club prestige fill.</p>`;
    return;
  }

  const tier = data.club_tier || "—";
  const gap = Number(data.performance_gap);
  const gapLabel =
    Number.isFinite(gap) && gap !== 0
      ? `${gap > 0 ? "+" : ""}${gap.toFixed(2)} (${gap < 0 ? "below expectation" : "above expectation"})`
      : "On expectation";

  el.innerHTML = `
    <dl class="breakdown">
      <dt>Stadium capacity</dt><dd>${Number(data.capacity || 0).toLocaleString("en-GB")}</dd>
      <dt>Club tier</dt><dd>${tier} · prestige rank ${data.prestige_rank ?? "—"}</dd>
      <dt>Manager rating</dt><dd>${data.manager_rating ?? "—"}${tier !== "big" && data.manager_rating ? " (can lift expectation)" : ""}</dd>
      <dt>Season expectation</dt><dd>League ${data.expected_position ?? "—"} · ${Number(data.expected_points || 0).toFixed(2)} pts</dd>
      <dt>Current delivery</dt><dd>League ${data.actual_position ?? data.table_position ?? "—"} · ${Number(data.actual_points || 0).toFixed(2)} pts</dd>
      <dt>Performance gap</dt><dd>${gapLabel}</dd>
      <dt>Fill rate</dt><dd>${fillPct}% <span class="note">(floor ${data.min_fill_pct ?? 60}%)</span></dd>
      <dt>Est. gate per home match</dt><dd class="highlight">${formatMoney(data.total_gate)}</dd>
    </dl>
    <p class="note">Based on <b>club</b> prestige (5-season rolling) vs this season's results. Big clubs stay held to high standards; top managers raise the bar at medium/low clubs only.</p>
    <p class="note">League home games: <b>100%</b> to home club. Cup games: <b>50% / 50%</b>.</p>
  `;
}

function renderHomeFixtures(fixtures, clubShort) {
  const el = document.getElementById("homeFixturesList");
  if (!el) return;

  const home = fixtures
    .filter(
      (f) =>
        f.status === "scheduled" &&
        (f.home_club_short_name || "").toUpperCase() === clubShort.toUpperCase()
    )
    .slice(0, 8);

  if (!home.length) {
    el.innerHTML = '<p class="empty">No upcoming home league fixtures.</p>';
    return;
  }

  el.innerHTML = `
    <ul class="fixture-ul">
      ${home
        .map(
          (f) =>
            `<li>MD${f.matchday}: vs ${f.away_club_name || f.away_club_short_name}</li>`
        )
        .join("")}
    </ul>
  `;
}

function setExpansionHint(msg, isError = false) {
  const el = document.getElementById("expansionHint");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("expansion-hint--error", isError);
}

async function refreshQuoteSelect() {
  const quotes = await loadStadiumExpansionQuotes();
  const sel = document.getElementById("expansionQuoteSelect");
  const row = document.getElementById("expansionOrderRow");
  if (!sel || !row) return;

  if (!quotes.length) {
    row.style.display = "none";
    sel.innerHTML = "";
    return;
  }

  row.style.display = "flex";
  sel.innerHTML = quotes
    .map(
      (q) =>
        `<option value="${q.id}">${formatQuoteLabel(q)}</option>`
    )
    .join("");
}

function renderExpansionActions(status) {
  const el = document.getElementById("expansionOrderActions");
  if (!el || !status?.active_order_id) {
    if (el) el.innerHTML = "";
    return;
  }

  const id = status.active_order_id;
  const st = status.order_status;
  const parts = [];

  if (st === "pre_build" && (status.pre_build_day || 0) < 7) {
    parts.push(
      `<button type="button" class="btn-secondary btn-danger" data-action="pre-cancel" data-id="${id}">Cancel order (full refund)</button>`
    );
  }

  if (st === "awaiting_goahead" && status.day7_decision_open) {
    parts.push(
      `<button type="button" class="btn-result" data-action="continue" data-id="${id}">Continue to build</button>`,
      `<button type="button" class="btn-secondary btn-danger" data-action="day7-cancel" data-id="${id}">Cancel build (Rapid Build fee)</button>`
    );
  }

  if (st === "building" && Number(status.seats_delivered || 0) === 0) {
    parts.push(
      `<button type="button" class="btn-secondary btn-danger" data-action="build-cancel" data-id="${id}">Cancel build (full refund)</button>`
    );
  }

  el.innerHTML = parts.join("");

  el.querySelectorAll("button").forEach((btn) => {
    btn.onclick = async () => {
      const orderId = Number(btn.dataset.id);
      const action = btn.dataset.action;
      btn.disabled = true;
      let result = { ok: false };

      if (action === "pre-cancel") result = await cancelPreBuildOrder(orderId);
      else if (action === "continue") result = await day7StadiumDecision(orderId, true);
      else if (action === "day7-cancel") {
        if (!confirm("Cancel build? Rapid Build Co cancellation fee will be deducted from your refund.")) {
          btn.disabled = false;
          return;
        }
        result = await day7StadiumDecision(orderId, false);
      } else if (action === "build-cancel") result = await cancelBuildOrder(orderId);

      btn.disabled = false;

      if (!result.ok) {
        setExpansionHint(result.msg || "Action failed.", true);
        return;
      }

      setExpansionHint("Updated.");
      await refreshExpansionPanel();
      await refreshStadiumData();
    };
  });
}

async function refreshExpansionPanel() {
  const status = await loadStadiumExpansionStatus();
  const blockedEl = document.getElementById("expansionBlocked");
  const buildEl = document.getElementById("expansionBuildStatus");
  const formEl = document.getElementById("expansionActiveForm");
  const quotaEl = document.getElementById("expansionQuota");
  const capMeta = document.getElementById("stadiumCapMeta");

  if (!status) {
    if (blockedEl) {
      blockedEl.innerHTML =
        '<p class="empty">Expansion unavailable — run <code>supabase/sql/stadium_expansion.sql</code> in Supabase.</p>';
    }
    if (formEl) formEl.style.display = "none";
    return;
  }

  const current = Number(status.current_capacity || 0);
  const max = Number(status.max_capacity || 0);
  const base = Number(status.base_capacity || 0);
  const headroom = Number(status.headroom || 0);
  const cps = formatMoney(status.cost_per_seat);

  document.getElementById("stadiumCapacity").textContent =
    current.toLocaleString("en-GB");

  if (capMeta) {
    capMeta.textContent = `(max ${max.toLocaleString("en-GB")} · original ${base.toLocaleString("en-GB")})`;
  }

  if (quotaEl) {
    quotaEl.textContent = `Headroom: ${headroom.toLocaleString("en-GB")} seats · ${cps} per seat at current size`;
  }

  if (buildEl) buildEl.innerHTML = renderBuildStatusHtml(status);

  const blocked = expansionBlockedReason(status);
  const hasActive = Boolean(status.active_order_id);

  if (blocked && !hasActive) {
    if (blockedEl) blockedEl.innerHTML = `<p class="expansion-hint">${blocked}</p>`;
    if (formEl) formEl.style.display = "none";
    if (buildEl) buildEl.innerHTML = "";
    return;
  }

  if (blockedEl) blockedEl.innerHTML = "";
  if (formEl) formEl.style.display = hasActive ? "none" : "block";

  renderExpansionActions(status);
  await refreshQuoteSelect();
}

async function refreshStadiumData() {
  if (!clubShortName) return;

  const estimate = await estimateGateForClub(supabase, clubShortName);
  renderGateBreakdown(estimate);

  const standings = await loadStandings(supabase);
  const row = standings.find((s) => s.club_short_name === clubShortName);
  if (row && document.getElementById("leaguePos")) {
    document.getElementById("leaguePos").textContent =
      `${DIVISION_LABELS[row.division] || row.division} — ${row.table_position}${ordinal(row.table_position)}`;
  }
}

function wireExpansionForm() {
  document.getElementById("expansionQuoteBtn")?.addEventListener("click", async () => {
    const seats = Number(document.getElementById("expansionSeats")?.value);
    if (!Number.isFinite(seats) || seats <= 0) {
      setExpansionHint("Enter how many seats to add.", true);
      return;
    }

    const btn = document.getElementById("expansionQuoteBtn");
    btn.disabled = true;
    const result = await createStadiumQuote(Math.floor(seats));
    btn.disabled = false;

    if (!result.ok) {
      const msg = result.msg || "";
      if (msg.includes("stadium_expansion")) {
        setExpansionHint(
          "Run supabase/sql/stadium_expansion.sql in Supabase first.",
          true
        );
      } else {
        setExpansionHint(msg, true);
      }
      return;
    }

    const q = result.quote;
    setExpansionHint(
      `Quote: +${Number(q.seats).toLocaleString("en-GB")} seats for ${formatMoney(q.total_cost)} (${formatMoney(q.cost_per_seat)}/seat).`
    );
    await refreshQuoteSelect();
  });

  document.getElementById("expansionOrderBtn")?.addEventListener("click", async () => {
    const quoteId = Number(document.getElementById("expansionQuoteSelect")?.value);
    if (!quoteId) {
      setExpansionHint("Create or select a quote first.", true);
      return;
    }

    const btn = document.getElementById("expansionOrderBtn");
    btn.disabled = true;
    const result = await placeStadiumOrder(quoteId);
    btn.disabled = false;

    if (!result.ok) {
      setExpansionHint(result.msg || "Order failed.", true);
      return;
    }

    setExpansionHint("Order placed — payment deducted. Pre-build begins (day 1).");
    document.getElementById("expansionSeats").value = "";
    await refreshExpansionPanel();
    await refreshStadiumData();
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Stadium, Capacity, base_capacity")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("pageMeta").textContent =
      "No club linked to this account.";
    return;
  }

  await loadClubsMap();
  clubShortName = club.ShortName;

  document.getElementById("pageTitle").textContent =
    `${fullClubName(clubShortName) || club.Club} — Stadium`;
  document.getElementById("stadiumName").textContent = club.Stadium || "—";
  document.getElementById("stadiumCapacity").textContent = Number(
    club.Capacity || 0
  ).toLocaleString("en-GB");

  renderStadiumPhoto(clubShortName, club.Stadium);

  wireExpansionForm();
  await refreshExpansionPanel();

  const estimate = await estimateGateForClub(supabase, clubShortName);
  renderGateBreakdown(estimate);

  const archive = await loadClubSeasonArchive(supabase, clubShortName);
  const archEl = document.getElementById("historyNote");
  if (archEl) {
    archEl.textContent = archive.length
      ? `Club prestige uses ${archive.length} archived season(s) in the rolling window (plus live season form).`
      : "No archive rows yet — prestige and fill use live season data until seasons are archived.";
  }

  const standings = await loadStandings(supabase);
  const row = standings.find((s) => s.club_short_name === clubShortName);
  if (row && document.getElementById("leaguePos")) {
    document.getElementById("leaguePos").textContent =
      `${DIVISION_LABELS[row.division] || row.division} — ${row.table_position}${ordinal(row.table_position)}`;
  }

  const { data: reg } = await supabase
    .from("competition_club_season_public")
    .select("division")
    .eq("club_short_name", clubShortName)
    .maybeSingle();

  const division = reg?.division || row?.division;
  if (division) {
    const fixtures = await loadLeagueFixtures(supabase, division);
    renderHomeFixtures(fixtures, clubShortName);
  }
});

function ordinal(n) {
  const s = ["th", "st", "nd", "rd"];
  const v = n % 100;
  return s[(v - 20) % 10] || s[v] || s[0];
}
