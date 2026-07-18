import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";
import { displayClubName, clubPageHref } from "./clubs_lookup.js";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function qs(name) {
  return new URLSearchParams(window.location.search).get(name);
}

function showError(msg) {
  const el = document.getElementById("profileError");
  if (!el) return;
  el.style.display = "block";
  el.textContent = msg;
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

function clubLink(shortName, name) {
  if (!shortName) return "—";
  const label = name || displayClubName(shortName) || shortName;
  const href = clubPageHref(shortName);
  return href
    ? `<a class="gpsl-link" href="${href}">${escapeHtml(label)}</a>`
    : escapeHtml(label);
}

function badgePublicUrl(path) {
  if (!path) return null;
  const { data } = supabase.storage.from("owner-badges").getPublicUrl(path);
  return data?.publicUrl || null;
}

function renderHeader(profile, totals) {
  const tag = profile.owner_tag || profile.owner_name || "Owner";
  document.title = `${tag} — GPSL`;
  document.getElementById("ownerTitle").textContent = tag;

  const meta = [
    profile.current_club_name
      ? `Club: ${profile.current_club_name}`
      : profile.status
        ? `Status: ${profile.status}`
        : null,
    profile.nation_name ? `Nation: ${profile.nation_name}` : null,
  ]
    .filter(Boolean)
    .join(" · ");
  document.getElementById("ownerMeta").textContent = meta || "GPSL owner";

  const img = document.getElementById("ownerBadge");
  const fallback = document.getElementById("ownerBadgeFallback");
  const url = badgePublicUrl(profile.badge_path);
  if (url) {
    img.src = url;
    img.alt = tag;
    img.hidden = false;
    fallback.hidden = true;
  } else {
    img.hidden = true;
    fallback.hidden = false;
    fallback.textContent = String(tag).slice(0, 2).toUpperCase();
  }

  const t = totals || {};
  document.getElementById("totalsRow").innerHTML = `
    <span><b>${t.seasons ?? 0}</b> seasons</span>
    <span><b>${t.won ?? 0}</b>-${t.drawn ?? 0}-${t.lost ?? 0}</span>
    <span>Win % <b>${t.win_pct != null ? t.win_pct : "—"}</b></span>
    <span>Pts <b>${t.pts ?? 0}</b></span>
    <span>GD <b>${t.gd ?? 0}</b></span>
  `;

  const edit = document.getElementById("badgeEdit");
  if (edit) edit.hidden = !profile.is_self;
}

function renderTransfers(transfers, highPaid, highRecv) {
  const el = document.getElementById("transfersPanel");
  const spent = Number(transfers?.spent || 0);
  const received = Number(transfers?.received || 0);

  const paidLine = highPaid
    ? `<div class="highlight">Highest fee paid: <b>${formatMoney(highPaid.fee)}</b> for
        ${escapeHtml(highPaid.player_name || highPaid.player_id || "player")}
        (${clubLink(highPaid.club_short_name)}) —
        ${escapeHtml(highPaid.season_label || formatWhen(highPaid.transfer_time))}</div>`
    : `<div class="highlight">Highest fee paid: <span class="empty">—</span></div>`;

  const recvLine = highRecv
    ? `<div class="highlight">Highest fee received: <b>${formatMoney(highRecv.fee)}</b> for
        ${escapeHtml(highRecv.player_name || highRecv.player_id || "player")}
        (${clubLink(highRecv.club_short_name)}) —
        ${escapeHtml(highRecv.season_label || formatWhen(highRecv.transfer_time))}</div>`
    : `<div class="highlight">Highest fee received: <span class="empty">—</span></div>`;

  el.innerHTML = `
    <div class="totals" style="margin-top:0;margin-bottom:12px">
      <span>Spent on players <b>${formatMoney(spent)}</b></span>
      <span>Received for players <b>${formatMoney(received)}</b></span>
    </div>
    ${paidLine}
    ${recvLine}
  `;
}

function renderSeasons(rows) {
  const el = document.getElementById("seasonsPanel");
  if (!rows?.length) {
    el.innerHTML = '<p class="empty">No archived season records yet.</p>';
    return;
  }
  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th><th>Club</th><th>Div</th><th class="num">Pos</th>
          <th class="num">P</th><th class="num">W</th><th class="num">D</th><th class="num">L</th>
          <th class="num">F</th><th class="num">A</th><th class="num">GD</th><th class="num">Pts</th>
          <th class="num">Win%</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `<tr>
          <td>${escapeHtml(r.season_label)}</td>
          <td>${clubLink(r.club_short_name, r.club_name)}</td>
          <td>${escapeHtml(r.division || "—")}</td>
          <td class="num">${r.final_position ?? "—"}</td>
          <td class="num">${r.mp ?? 0}</td>
          <td class="num">${r.won ?? 0}</td>
          <td class="num">${r.drawn ?? 0}</td>
          <td class="num">${r.lost ?? 0}</td>
          <td class="num">${r.gf ?? 0}</td>
          <td class="num">${r.ga ?? 0}</td>
          <td class="num">${r.gd ?? 0}</td>
          <td class="num"><b>${r.pts ?? 0}</b></td>
          <td class="num">${r.win_pct != null ? r.win_pct : "—"}</td>
        </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function renderTrophies(rows) {
  const el = document.getElementById("trophiesPanel");
  if (!rows?.length) {
    el.innerHTML = '<p class="empty">No trophies archived yet.</p>';
    return;
  }
  el.innerHTML = `<ul style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:8px">
    ${rows
      .map(
        (t) => `<li class="highlight">
      <b>${escapeHtml(t.honour_label)}</b>
      <div class="note">${escapeHtml(t.season_label)} · ${clubLink(t.club_short_name, t.club_name)}</div>
    </li>`
      )
      .join("")}
  </ul>`;
}

function awardLabel(type) {
  return (
    {
      ballon_dor: "Ballon d'Or",
      golden_boot: "Golden Boot",
      golden_playmaker: "Golden Playmaker",
      golden_glove: "Golden Glove",
      season_potm: "Season POTM",
      championship_player_of_season: "Championship Player of the Season",
      team_of_season: "Team of the Season",
    }[type] || type
  );
}

function renderAwards(rows) {
  const el = document.getElementById("awardsPanel");
  if (!rows?.length) {
    el.innerHTML = '<p class="empty">No awards recorded for their clubs yet.</p>';
    return;
  }
  el.innerHTML = `<ul style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:8px">
    ${rows
      .map(
        (a) => `<li class="highlight">
      <b>${escapeHtml(awardLabel(a.award_type))}</b>
      <div class="note">${escapeHtml(a.season_label)}${
          a.gpsl_month ? ` · ${escapeHtml(a.gpsl_month)}` : ""
        } · ${clubLink(a.club_short_name)} · ${escapeHtml(a.player_name || a.player_id || "")}</div>
    </li>`
      )
      .join("")}
  </ul>`;
}

async function uploadBadge(ownerId) {
  const status = document.getElementById("badgeStatus");
  const file = document.getElementById("badgeFile")?.files?.[0];
  if (!file) {
    status.textContent = "Choose an image first.";
    return;
  }
  if (file.size > 1024 * 1024) {
    status.textContent = "Max 1 MB.";
    return;
  }

  status.textContent = "Uploading…";
  await supabase.rpc("owner_registry_ensure_self");

  const ext = (file.name.split(".").pop() || "png").toLowerCase().replace(/[^a-z0-9]/g, "");
  const path = `${ownerId}/badge.${ext || "png"}`;
  const { error: upErr } = await supabase.storage
    .from("owner-badges")
    .upload(path, file, { upsert: true, contentType: file.type });

  if (upErr) {
    status.textContent = "❌ " + upErr.message;
    return;
  }

  const { error } = await supabase.rpc("owner_registry_set_badge_path", { p_path: path });
  if (error) {
    status.textContent = "❌ " + error.message;
    return;
  }
  status.textContent = "✅ Badge saved.";
  await loadProfile(ownerId);
}

async function clearBadge(ownerId) {
  const status = document.getElementById("badgeStatus");
  status.textContent = "Removing…";
  const { error } = await supabase.rpc("owner_registry_set_badge_path", { p_path: null });
  if (error) {
    status.textContent = "❌ " + error.message;
    return;
  }
  status.textContent = "✅ Badge removed.";
  await loadProfile(ownerId);
}

async function loadProfile(ownerId) {
  const { data, error } = await supabase.rpc("owner_profile_bundle", {
    p_owner_id: ownerId,
  });

  if (error) {
    showError(
      error.message.includes("owner_profile_bundle")
        ? "Run supabase/sql/patches/owner_profile_and_badge.sql in Supabase."
        : error.message
    );
    return;
  }
  if (!data?.ok) {
    showError(data?.reason || "Owner not found.");
    return;
  }

  const profile = data.profile || {};
  renderHeader(profile, data.career_totals);
  renderTransfers(data.transfers, data.highest_fee_paid, data.highest_fee_received);
  renderSeasons(data.seasons || []);
  renderTrophies(data.trophies || []);
  renderAwards(data.awards || []);

  document.getElementById("badgeSaveBtn").onclick = () => uploadBadge(ownerId);
  document.getElementById("badgeClearBtn").onclick = () => clearBadge(ownerId);
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const ownerId = qs("owner");
  if (!ownerId) {
    showError("Missing owner id. Open this page from Owner rankings.");
    return;
  }
  await loadProfile(ownerId);
});
