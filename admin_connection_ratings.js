import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { loadCurrentSeason } from "./competition.js";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function starsHtml(n, label) {
  const v = Number(n) || 0;
  const filled = "★".repeat(Math.max(0, Math.min(5, v)));
  const empty = "☆".repeat(Math.max(0, 5 - v));
  return `<span class="stars-${v}">${filled}${empty}</span> ${escapeHtml(label || "")}`;
}

function monthLabel(m) {
  if (!m) return "—";
  return String(m).charAt(0).toUpperCase() + String(m).slice(1);
}

async function loadSeasons() {
  const sel = document.getElementById("seasonFilter");
  if (!sel) return;
  const current = await loadCurrentSeason(supabase);
  const { data } = await supabase
    .from("competition_seasons")
    .select("id, label, is_current")
    .order("id", { ascending: false })
    .limit(12);
  const rows = data || [];
  sel.innerHTML =
    `<option value="">All seasons</option>` +
    rows
      .map(
        (s) =>
          `<option value="${s.id}"${
            current?.id === s.id ? " selected" : ""
          }>${escapeHtml(s.label || s.id)}${s.is_current ? " (current)" : ""}</option>`
      )
      .join("");
}

async function loadList() {
  const status = document.getElementById("listStatus");
  const table = document.getElementById("ratingsTable");
  const summary = document.getElementById("summaryGrid");
  status.textContent = "Loading…";
  table.innerHTML = "";
  summary.innerHTML = "";

  const seasonRaw = document.getElementById("seasonFilter")?.value;
  const maxRaw = document.getElementById("maxStarsFilter")?.value;
  const p_season_id = seasonRaw ? Number(seasonRaw) : null;
  let p_max_stars = maxRaw === "" ? null : Number(maxRaw);
  if (maxRaw === "5") p_max_stars = null;

  const { data, error } = await supabase.rpc("admin_fixture_connection_ratings_list", {
    p_season_id,
    p_max_stars,
    p_limit: 300,
  });

  if (error) {
    status.textContent =
      error.message?.includes("admin_fixture_connection_ratings_list") ||
      error.message?.includes("schema cache")
        ? "Run supabase/sql/patches/fixture_connection_ratings_20261022.sql in Supabase."
        : error.message || "Failed to load";
    return;
  }

  const rows = Array.isArray(data?.rows) ? data.rows : [];
  const poor = Array.isArray(data?.poor_opponent_summary)
    ? data.poor_opponent_summary
    : [];

  if (!poor.length) {
    summary.innerHTML =
      '<p style="color:#888;margin:0;grid-column:1/-1;">No 1–2★ ratings as opponent yet.</p>';
  } else {
    summary.innerHTML = poor
      .map(
        (c) => `<div class="summary-card">
        <b>${escapeHtml(String(c.club_short_name || "").toUpperCase())}</b>
        <div style="font-size:12px;color:#aaa;margin-top:4px;">
          ${c.poor_as_opponent} poor (1–2★) of ${c.ratings_as_opponent} · avg ${escapeHtml(
            String(c.avg_stars_as_opponent ?? "—")
          )}★
        </div>
      </div>`
      )
      .join("");
  }

  status.textContent = `${rows.length} rating(s)`;

  if (!rows.length) {
    table.innerHTML = `<p style="color:#888;">None for this filter.</p>`;
    return;
  }

  table.innerHTML = `
    <table class="cq">
      <thead>
        <tr>
          <th>When</th>
          <th>Fixture</th>
          <th>Reporter</th>
          <th>Opponent</th>
          <th>Connection</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((r) => {
            const when = r.created_at
              ? new Date(r.created_at).toLocaleString("en-GB", {
                  day: "2-digit",
                  month: "short",
                  hour: "2-digit",
                  minute: "2-digit",
                })
              : "—";
            const fx = `${escapeHtml(
              String(r.home_club_short_name || "").toUpperCase()
            )} vs ${escapeHtml(String(r.away_club_short_name || "").toUpperCase())}`;
            const meta = [
              r.season_label,
              monthLabel(r.gpsl_month),
              r.competition_type,
              r.cup_code || r.division || "",
              r.matchday != null ? `MD${r.matchday}` : "",
            ]
              .filter(Boolean)
              .join(" · ");
            return `<tr>
              <td>${escapeHtml(when)}<div style="color:#666;font-size:11px;">${escapeHtml(
                meta
              )}</div></td>
              <td>${fx}</td>
              <td><b>${escapeHtml(
                String(r.reporter_club_short_name || "").toUpperCase()
              )}</b></td>
              <td>${escapeHtml(String(r.opponent_club_short_name || "").toUpperCase())}</td>
              <td>${starsHtml(r.stars, r.label)}</td>
              <td><a href="matchday.html?fixture=${r.fixture_id}" style="color:#9cf;">Match Day</a></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>
  `;
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
  if (!(await isGpslAdminUser())) {
    document.querySelector(".card").innerHTML =
      '<p class="note" style="color:#f99;">Admin only.</p>';
    return;
  }

  await loadSeasons();
  document.getElementById("reloadBtn")?.addEventListener("click", () => void loadList());
  document.getElementById("seasonFilter")?.addEventListener("change", () => void loadList());
  document.getElementById("maxStarsFilter")?.addEventListener("change", () => void loadList());
  await loadList();
});
