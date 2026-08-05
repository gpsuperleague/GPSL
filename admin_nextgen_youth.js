import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";

primeAdminPageChrome();

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function parsePlayerIds(raw) {
  return [
    ...new Set(
      String(raw || "")
        .split(/[\s,;]+/)
        .map((s) => s.trim())
        .filter(Boolean)
    ),
  ];
}

function renderList(data) {
  const meta = document.getElementById("listMeta");
  const body = document.getElementById("playerBody");
  const ta = document.getElementById("playerIds");
  const players = data?.players || [];
  const boost = Math.round(Number(data?.boost_pct || 0.1) * 100);

  if (meta) {
    const when = data?.refreshed_at
      ? new Date(data.refreshed_at).toLocaleString()
      : "never";
    meta.innerHTML = `Season <b>${escapeHtml(data?.season_label || data?.season_id || "—")}</b>
      · ${players.length} player(s) · +${boost}% MV boost
      · last refresh ${escapeHtml(when)}.`;
  }

  if (ta && !ta.dataset.dirty) {
    ta.value = players.map((p) => p.player_id).join("\n");
  }

  if (!body) return;
  if (!players.length) {
    body.innerHTML = `<tr><td colspan="7" class="muted">No players on the current-season Next Gen list.</td></tr>`;
    return;
  }

  body.innerHTML = players
    .map((p) => {
      const club = p.club ? displayClubName(p.club) || p.club : "—";
      return `
      <tr>
        <td><b>${escapeHtml(p.player_name || p.player_id)}</b></td>
        <td>${escapeHtml(club)}</td>
        <td>${escapeHtml(p.position || "—")}</td>
        <td>${escapeHtml(p.age ?? "—")}</td>
        <td>${escapeHtml(p.rating ?? "—")}</td>
        <td>${formatMoney(Number(p.market_value || 0))}</td>
        <td><code>${escapeHtml(p.player_id)}</code></td>
      </tr>`;
    })
    .join("");
}

async function reloadList() {
  setStatus("listStatus", "Loading…", true);
  const { data, error } = await supabase.rpc("nextgen_youth_list", {
    p_season_id: null,
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("nextgen_youth_list")
        ? "Run supabase/sql/patches/nextgen_youth_mv_boost.sql first."
        : error.message,
      false
    );
    return;
  }
  const ta = document.getElementById("playerIds");
  if (ta) delete ta.dataset.dirty;
  renderList(data);
  setStatus(
    "listStatus",
    `${(data?.players || []).length} player(s) on current season list.`,
    true
  );
}

async function refreshList(ids) {
  if (
    !confirm(
      `Replace the current-season Next Gen list with ${ids.length} player(s)?\n\nMarket values will recalc for anyone who enters or leaves (+10% on / off).`
    )
  ) {
    return;
  }

  setStatus("listStatus", "Refreshing list and recalculating market values…");
  const { data, error } = await supabase.rpc("admin_nextgen_youth_refresh", {
    p_player_ids: ids,
    p_season_id: null,
    p_note: null,
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("admin_nextgen_youth_refresh")
        ? "Run supabase/sql/patches/nextgen_youth_mv_boost.sql first."
        : error.message,
      false
    );
    return;
  }

  const ta = document.getElementById("playerIds");
  if (ta) delete ta.dataset.dirty;
  await reloadList();
  setStatus(
    "listStatus",
    `✅ Refreshed ${data?.season_label || "season"}: ${data?.player_count ?? 0} on list (added ${data?.added ?? 0}, removed ${data?.removed ?? 0}, recalculated ${data?.recalculated ?? 0}).`,
    true
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  await loadClubsMap();

  document.getElementById("playerIds")?.addEventListener("input", (e) => {
    e.target.dataset.dirty = "1";
  });
  document.getElementById("reloadBtn")?.addEventListener("click", () => reloadList());
  document.getElementById("refreshBtn")?.addEventListener("click", () => {
    const ids = parsePlayerIds(document.getElementById("playerIds")?.value);
    refreshList(ids);
  });
  document.getElementById("clearBtn")?.addEventListener("click", () => {
    const ta = document.getElementById("playerIds");
    if (ta) {
      ta.value = "";
      ta.dataset.dirty = "1";
    }
    refreshList([]);
  });

  try {
    await reloadList();
  } catch (e) {
    setStatus("listStatus", e.message || String(e), false);
  }
});
