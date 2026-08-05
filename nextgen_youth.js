import { initGlobal, supabase } from "./global.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, displayClubName, clubPageHref } from "./clubs_lookup.js";
import {
  playerNameLinkHtml,
  playerThumbLinkHtml,
} from "./player_links.js";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

async function loadList() {
  const status = document.getElementById("listStatus");
  const body = document.getElementById("playerBody");
  const meta = document.getElementById("pageMeta");
  const tag = document.getElementById("boostTag");

  const { data, error } = await supabase.rpc("nextgen_youth_list", {
    p_season_id: null,
  });

  if (error) {
    if (status) {
      status.textContent = error.message.includes("nextgen_youth_list")
        ? "Next Gen Youth is not set up yet (admin must run nextgen_youth_mv_boost.sql)."
        : error.message;
    }
    if (body) {
      body.innerHTML = `<tr><td colspan="7" class="empty">Unavailable.</td></tr>`;
    }
    return;
  }

  const players = data?.players || [];
  const boostPct = Math.round(Number(data?.boost_pct || 0.1) * 100);
  if (tag) tag.textContent = `+${boostPct}% MV`;

  if (meta) {
    const when = data?.refreshed_at
      ? new Date(data.refreshed_at).toLocaleString()
      : "not yet refreshed";
    meta.innerHTML = `Current season: <b>${escapeHtml(data?.season_label || "—")}</b>
      · ${players.length} player${players.length === 1 ? "" : "s"}
      · last admin refresh ${escapeHtml(when)}.
      While listed, market value includes a <b>+${boostPct}%</b> boost (removed when they leave the list).`;
  }

  if (status) {
    status.textContent = players.length
      ? `${players.length} Next Gen player${players.length === 1 ? "" : "s"}.`
      : "No players on the current-season list yet.";
  }

  if (!body) return;
  if (!players.length) {
    body.innerHTML = `<tr><td colspan="7" class="empty">No Next Gen Youth players this season.</td></tr>`;
    return;
  }

  body.innerHTML = players
    .map((p) => {
      const clubLabel = p.club ? displayClubName(p.club) || p.club : "—";
      const clubCell = p.club
        ? `<a href="${escapeHtml(clubPageHref(p.club))}" style="color:#ff9900;">${escapeHtml(clubLabel)}</a>`
        : "—";
      return `
      <tr>
        <td>
          ${playerThumbLinkHtml(p.player_id, { alt: p.player_name || "" })}
          ${playerNameLinkHtml(p.player_id, p.player_name || p.player_id)}
        </td>
        <td>${clubCell}</td>
        <td>${escapeHtml(p.nation || "—")}</td>
        <td>${escapeHtml(p.position || "—")}</td>
        <td>${escapeHtml(p.age ?? "—")}</td>
        <td>${escapeHtml(p.rating ?? "—")}</td>
        <td>${formatMoney(Number(p.market_value || 0))} <span class="boost-tag">+${boostPct}%</span></td>
      </tr>`;
    })
    .join("");
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  await loadList();
});
