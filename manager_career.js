import { supabase, initGlobal } from "./global.js";
import {
  loadClubsMap,
  displayClubName,
  clubPageHref,
} from "./clubs_lookup.js";
import {
  loadManagerPortraitManifest,
  applyManagerPortrait,
  managerInitials,
} from "./manager_images.js";
import { formatMoney } from "./competition.js";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

function clubCell(shortName) {
  if (!shortName) return "—";
  const label = displayClubName(shortName) || shortName;
  const href = clubPageHref(shortName);
  return href
    ? `<a class="gpsl-link" href="${href}">${escapeHtml(label)}</a>`
    : escapeHtml(label);
}

function dealLabel(kind) {
  switch (kind) {
    case "draft":
      return "Draft";
    case "market":
      return "Market";
    case "sack":
      return "Sacked";
    case "transfer":
      return "Transfer";
    case "expire":
      return "Expired";
    case "admin":
      return "Admin";
    case "assign":
      return "Direct";
    default:
      return kind || "—";
  }
}

function showError(msg) {
  const el = document.getElementById("careerError");
  if (!el) return;
  el.style.display = "block";
  el.textContent = msg;
}

function renderHeader(manager) {
  document.getElementById("managerTitle").textContent = manager.name || "Manager";
  const club = manager.contracted_club
    ? displayClubName(manager.contracted_club) || manager.contracted_club
    : "Free agent";
  document.getElementById("managerMeta").textContent = [
    manager.nation,
    manager.rating != null ? `Rating ${manager.rating}` : null,
    manager.age != null ? `Age ${manager.age}` : null,
    club,
  ]
    .filter(Boolean)
    .join(" · ");

  document.getElementById("totalsRow").innerHTML = `
    <span>Market value <b>${formatMoney(Number(manager.market_value || 0))}</b></span>
    <span>Wage <b>${formatMoney(Number(manager.weekly_wage || 0))}</b></span>
    <span>Contract <b>${manager.contract_seasons_remaining ?? 0}</b> season(s)</span>
  `;

  const img = document.getElementById("managerImg");
  const fallback = document.getElementById("managerFallback");
  if (fallback) {
    fallback.textContent = managerInitials(manager.name);
    fallback.hidden = false;
  }
  applyManagerPortrait(img, manager.slug, {
    fallbackEl: fallback,
    name: manager.name,
  });
}

function renderStints(stints) {
  const el = document.getElementById("stintsPanel");
  if (!stints?.length) {
    el.innerHTML =
      '<p class="empty">No club spells recorded yet. Signings and sacks will appear here after the history patch/backfill.</p>';
    return;
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Club</th>
          <th>Season</th>
          <th>Joined</th>
          <th>Left</th>
          <th>Fee in</th>
          <th>End</th>
        </tr>
      </thead>
      <tbody>
        ${stints
          .map(
            (s) => `
          <tr>
            <td>${clubCell(s.club_short)}</td>
            <td>${escapeHtml(s.season_label || "—")}</td>
            <td>${formatWhen(s.started_at)} <span class="type-pill ${escapeHtml(s.start_kind || "")}">${escapeHtml(dealLabel(s.start_kind))}</span></td>
            <td>${s.is_current ? "Current" : formatWhen(s.ended_at)}</td>
            <td>${formatMoney(Number(s.start_fee || 0))}</td>
            <td>${
              s.end_kind
                ? `<span class="type-pill ${escapeHtml(s.end_kind)}">${escapeHtml(dealLabel(s.end_kind))}</span>${
                    s.end_fee != null ? ` · ${formatMoney(Number(s.end_fee))}` : ""
                  }`
                : "—"
            }</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function renderTransfers(transfers) {
  const el = document.getElementById("transfersPanel");
  if (!transfers?.length) {
    el.innerHTML = '<p class="empty">No transfer / signing fees recorded yet.</p>';
    return;
  }

  // Deduplicate near-identical rows (listing + ledger for same signing)
  const seen = new Set();
  const rows = [];
  for (const t of transfers) {
    const key = `${t.to_club}|${Number(t.fee || 0)}|${String(t.at).slice(0, 10)}|${t.deal_kind}`;
    if (seen.has(key)) continue;
    seen.add(key);
    rows.push(t);
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Date</th>
          <th>From</th>
          <th>To</th>
          <th>Fee</th>
          <th>Type</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (t) => `
          <tr>
            <td>${formatWhen(t.at)}</td>
            <td>${t.from_club ? clubCell(t.from_club) : "Free agent"}</td>
            <td>${clubCell(t.to_club)}</td>
            <td>${formatMoney(Number(t.fee || 0))}</td>
            <td><span class="type-pill ${escapeHtml(t.deal_kind || "")}">${escapeHtml(dealLabel(t.deal_kind))}</span></td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function renderTrophies(trophies) {
  const el = document.getElementById("trophiesPanel");
  if (!trophies?.length) {
    el.innerHTML =
      '<p class="empty">No archived trophies yet for clubs this manager was managing.</p>';
    return;
  }

  el.innerHTML = `
    <ul class="trophy-list">
      ${trophies
        .map(
          (t) => `
        <li class="trophy-item">
          <div>
            <div class="trophy-title">${escapeHtml(t.honour_label || "Winner")}</div>
            <div class="trophy-meta">${escapeHtml(t.season_label || "")} · ${clubCell(t.club_short)}</div>
          </div>
        </li>`
        )
        .join("")}
    </ul>`;
}

function renderMotm(rows) {
  const el = document.getElementById("motmPanel");
  if (!el) return;
  if (!rows?.length) {
    el.innerHTML =
      '<p class="empty">No Manager of the Month awards yet. Run patches/manager_of_the_month.sql — awarded on End GPSL Month.</p>';
    return;
  }
  el.innerHTML = `
    <ul class="trophy-list">
      ${rows
        .map(
          (a) => `
        <li class="trophy-item">
          <div>
            <div class="trophy-title">Manager of the Month — ${escapeHtml(a.gpsl_month || "")}</div>
            <div class="trophy-meta">${escapeHtml(a.season_label || "")} · ${clubCell(
              a.club_short_name
            )} · ${a.won ?? 0}-${a.drawn ?? 0}-${a.lost ?? 0} (${a.pts ?? 0} pts)</div>
          </div>
        </li>`
        )
        .join("")}
    </ul>`;
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

  const params = new URLSearchParams(window.location.search);
  const managerId = Number(params.get("manager"));
  if (!Number.isFinite(managerId)) {
    showError("Missing manager id.");
    return;
  }

  await Promise.all([loadClubsMap(), loadManagerPortraitManifest()]);

  const { data, error } = await supabase.rpc("manager_career_bundle", {
    p_manager_id: managerId,
  });

  if (error) {
    showError(
      error.message?.includes("manager_career_bundle")
        ? "Run supabase/sql/patches/manager_career_history.sql in Supabase first."
        : error.message || "Could not load manager career."
    );
    return;
  }

  if (!data?.ok) {
    showError("Manager not found.");
    return;
  }

  renderHeader(data.manager || {});
  renderStints(data.stints || []);
  renderTransfers(data.transfers || []);
  renderTrophies(data.trophies || []);

  const { data: motmRows, error: motmErr } = await supabase
    .from("competition_manager_month_awards_public")
    .select("*")
    .eq("manager_id", managerId)
    .order("season_id", { ascending: false })
    .order("gpsl_month", { ascending: false });
  if (motmErr && /competition_manager_month/.test(motmErr.message || "")) {
    renderMotm([]);
  } else {
    renderMotm(motmRows || []);
  }
});
