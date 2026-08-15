import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let seasons = [];
let nations = [];
let selectedSeasonId = null;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function seasonId() {
  const sel = document.getElementById("seasonSelect");
  const v = sel?.value ? Number(sel.value) : null;
  return Number.isFinite(v) ? v : selectedSeasonId;
}

function seasonOptionHtml(s) {
  const tag = s.is_current ? " (current)" : ` (${s.status || ""})`;
  return `<option value="${s.id}">${escapeHtml(s.label || `Season ${s.id}`)}${tag}</option>`;
}

function syncCopyFromSelect() {
  const copySel = document.getElementById("copyFromSelect");
  const target = seasonId();
  if (!copySel) return;
  const prev = copySel.value;
  const others = seasons.filter((s) => Number(s.id) !== Number(target));
  copySel.innerHTML =
    `<option value="">Select season…</option>` +
    others.map(seasonOptionHtml).join("");
  if (prev && others.some((s) => String(s.id) === prev)) {
    copySel.value = prev;
  } else {
    const prior = others.find((s) => Number(s.id) < Number(target)) || others[0];
    if (prior) copySel.value = String(prior.id);
  }
}

async function loadSeasons() {
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .order("id", { ascending: false });
  if (error) throw error;
  seasons = data || [];
  const sel = document.getElementById("seasonSelect");
  if (!sel) return;
  sel.innerHTML = seasons.map(seasonOptionHtml).join("");
  const current = seasons.find((s) => s.is_current) || seasons[0];
  if (current) {
    sel.value = String(current.id);
    selectedSeasonId = current.id;
  }
  syncCopyFromSelect();
}

async function copyExclusionsFromSeason() {
  const toId = seasonId();
  const fromRaw = document.getElementById("copyFromSelect")?.value;
  const fromId = fromRaw ? Number(fromRaw) : null;
  if (!toId) {
    setStatus("listStatus", "Select a target season first.", false);
    return;
  }
  if (!fromId || !Number.isFinite(fromId)) {
    setStatus("listStatus", "Choose a season to copy from.", false);
    return;
  }
  if (fromId === toId) {
    setStatus("listStatus", "Source and target season are the same.", false);
    return;
  }
  if (
    !confirm(
      `Copy all excluded players and nations from season ${fromId} into season ${toId}?\n\nExisting rows on the target are kept / updated.`
    )
  ) {
    return;
  }

  setStatus("listStatus", "Copying exclusions…");
  const { data, error } = await supabase.rpc("admin_gpdb_copy_season_exclusions", {
    p_from_season_id: fromId,
    p_to_season_id: toId,
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("admin_gpdb_copy_season_exclusions")
        ? "Run patches/gpdb_season_exclusions_persist.sql first."
        : error.message,
      false
    );
    return;
  }
  await reloadLists();
  setStatus(
    "listStatus",
    `✅ Copied ${data?.players_copied ?? 0} player(s) and ${data?.nations_copied ?? 0} nation(s) from season ${fromId} → ${toId}.`,
    true
  );
}

async function loadNations() {
  const { data, error } = await supabase
    .from("international_nations")
    .select("code, name, active")
    .order("name", { ascending: true });
  if (error) throw error;
  nations = data || [];
  const sel = document.getElementById("nationSelect");
  if (!sel) return;
  sel.innerHTML =
    `<option value="">Select nation…</option>` +
    nations
      .map(
        (n) =>
          `<option value="${escapeHtml(n.code)}">${escapeHtml(n.name)} (${escapeHtml(n.code)})${
            n.active ? "" : " — inactive"
          }</option>`
      )
      .join("");
}

function isOpenSeason(s) {
  if (!s) return false;
  if (s.is_current) return true;
  const st = String(s.status || "").toLowerCase();
  return ["active", "preseason", "summer_break", "setup"].includes(st);
}

function setCount(elId, n) {
  const el = document.getElementById(elId);
  if (el) el.textContent = n == null ? "" : `(${n})`;
}

function renderActiveExclusions(playerRows, nationRows) {
  const pBody = document.getElementById("activePlayerBody");
  const nBody = document.getElementById("activeNationBody");
  setCount("activePlayerCount", playerRows.length);
  setCount("activeNationCount", nationRows.length);

  if (pBody) {
    if (!playerRows.length) {
      pBody.innerHTML = `<tr><td colspan="4" class="muted">No players currently excluded.</td></tr>`;
    } else {
      pBody.innerHTML = playerRows
        .map(
          (r) => `
        <tr>
          <td>
            <b>${escapeHtml(r.player_name || r.player_id)}</b><br>
            <small>${escapeHtml(r.player_id)} · ${escapeHtml(r.position || "—")} · OVR ${escapeHtml(
              r.rating ?? "—"
            )}</small>
          </td>
          <td>${escapeHtml(r.nation || "—")}</td>
          <td>${escapeHtml(r.season_label || `Season ${r.season_id}`)}</td>
          <td>${escapeHtml(r.reason || "—")}</td>
        </tr>`
        )
        .join("");
    }
  }

  if (nBody) {
    if (!nationRows.length) {
      nBody.innerHTML = `<tr><td colspan="3" class="muted">No nations currently excluded.</td></tr>`;
    } else {
      nBody.innerHTML = nationRows
        .map(
          (r) => `
        <tr>
          <td><b>${escapeHtml(r.nation_name || r.nation_code)}</b><br><small>${escapeHtml(
            r.nation_code
          )}</small></td>
          <td>${escapeHtml(r.season_label || `Season ${r.season_id}`)}</td>
          <td>${escapeHtml(r.reason || "—")}</td>
        </tr>`
        )
        .join("");
    }
  }

  setStatus(
    "activeStatus",
    `${playerRows.length} player(s), ${nationRows.length} nation(s) in effect across open seasons.`,
    true
  );
}

async function reloadActiveExclusions() {
  setStatus("activeStatus", "Loading current exclusions…", true);
  const open = seasons.filter(isOpenSeason);
  const targets = open.length ? open : seasons.slice(0, 1);
  if (!targets.length) {
    renderActiveExclusions([], []);
    setStatus("activeStatus", "No competition seasons found.", false);
    return;
  }

  const playerMap = new Map();
  const nationMap = new Map();
  let lastError = null;

  for (const s of targets) {
    const { data, error } = await supabase.rpc("admin_gpdb_exclusions_list", {
      p_season_id: s.id,
    });
    if (error) {
      lastError = error;
      continue;
    }
    const seasonLabel = data?.season_label || s.label || `Season ${s.id}`;
    const seasonIdVal = data?.season_id ?? s.id;
    for (const p of data?.players || []) {
      const key = String(p.player_id || "").trim();
      if (!key || playerMap.has(key)) continue;
      playerMap.set(key, { ...p, season_id: seasonIdVal, season_label: seasonLabel });
    }
    for (const n of data?.nations || []) {
      const key = String(n.nation_code || "").trim().toUpperCase();
      if (!key || nationMap.has(key)) continue;
      nationMap.set(key, { ...n, season_id: seasonIdVal, season_label: seasonLabel });
    }
  }

  if (lastError && !playerMap.size && !nationMap.size) {
    setStatus(
      "activeStatus",
      lastError.message.includes("admin_gpdb_exclusions_list")
        ? "Run supabase/sql/patches/gpdb_season_exclusions.sql first."
        : lastError.message,
      false
    );
    const pBody = document.getElementById("activePlayerBody");
    const nBody = document.getElementById("activeNationBody");
    if (pBody) pBody.innerHTML = `<tr><td colspan="4" class="muted">Could not load.</td></tr>`;
    if (nBody) nBody.innerHTML = `<tr><td colspan="3" class="muted">Could not load.</td></tr>`;
    setCount("activePlayerCount", 0);
    setCount("activeNationCount", 0);
    return;
  }

  const players = [...playerMap.values()].sort((a, b) =>
    String(a.player_name || a.player_id).localeCompare(String(b.player_name || b.player_id))
  );
  const nationsRows = [...nationMap.values()].sort((a, b) =>
    String(a.nation_name || a.nation_code).localeCompare(String(b.nation_name || b.nation_code))
  );
  renderActiveExclusions(players, nationsRows);
}

function renderPlayers(rows) {
  const tbody = document.getElementById("playerBody");
  setCount("seasonPlayerCount", rows?.length || 0);
  if (!tbody) return;
  if (!rows?.length) {
    tbody.innerHTML = `<tr><td colspan="4" class="muted">No excluded players.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map(
      (r) => `
    <tr>
      <td>
        <b>${escapeHtml(r.player_name || r.player_id)}</b><br>
        <small>${escapeHtml(r.player_id)} · ${escapeHtml(r.position || "—")} · OVR ${escapeHtml(
          r.rating ?? "—"
        )}</small>
        ${r.club ? `<br><small>${escapeHtml(r.club)}</small>` : ""}
      </td>
      <td>${escapeHtml(r.nation || "—")}</td>
      <td>${escapeHtml(r.reason || "—")}</td>
      <td><button type="button" class="button" data-unexclude-player="${escapeHtml(
        r.player_id
      )}">Remove</button></td>
    </tr>`
    )
    .join("");

  tbody.querySelectorAll("[data-unexclude-player]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      try {
        const { error } = await supabase.rpc("admin_gpdb_unexclude_player", {
          p_player_id: btn.dataset.unexcludePlayer,
          p_season_id: seasonId(),
        });
        if (error) throw error;
        await reloadLists();
      } catch (e) {
        setStatus("listStatus", e.message || String(e), false);
      }
    });
  });
}

function renderNations(rows) {
  const tbody = document.getElementById("nationBody");
  setCount("seasonNationCount", rows?.length || 0);
  if (!tbody) return;
  if (!rows?.length) {
    tbody.innerHTML = `<tr><td colspan="3" class="muted">No excluded nations.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map(
      (r) => `
    <tr>
      <td><b>${escapeHtml(r.nation_name || r.nation_code)}</b><br><small>${escapeHtml(
        r.nation_code
      )}</small></td>
      <td>${escapeHtml(r.reason || "—")}</td>
      <td><button type="button" class="button" data-unexclude-nation="${escapeHtml(
        r.nation_code
      )}">Remove</button></td>
    </tr>`
    )
    .join("");

  tbody.querySelectorAll("[data-unexclude-nation]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      try {
        const { data, error } = await supabase.rpc("admin_gpdb_unexclude_nation", {
          p_nation_code: btn.dataset.unexcludeNation,
          p_season_id: seasonId(),
        });
        if (error) throw error;
        const note = data?.note ? ` ${data.note}` : "";
        setStatus("listStatus", `Nation restored.${note}`, true);
        await reloadLists();
      } catch (e) {
        setStatus("listStatus", e.message || String(e), false);
      }
    });
  });
}

function renderManagers(rows) {
  const tbody = document.getElementById("managerBody");
  setCount("seasonManagerCount", rows?.length || 0);
  if (!tbody) return;
  if (!rows?.length) {
    tbody.innerHTML = `<tr><td colspan="3" class="muted">No managers match excluded nations.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map(
      (r) => `
    <tr>
      <td>
        <b>${escapeHtml(r.manager_name || r.manager_id)}</b>
        ${r.archived ? `<br><small class="muted">archived catalog</small>` : ""}
        <br><small>id ${escapeHtml(r.manager_id)} · rating ${escapeHtml(r.rating ?? "—")}</small>
      </td>
      <td>${escapeHtml(r.nation || "—")}</td>
      <td>${escapeHtml(r.club || "FA")}</td>
    </tr>`
    )
    .join("");
}

function renderClubs(rows) {
  const tbody = document.getElementById("clubBody");
  setCount("seasonClubCount", rows?.length || 0);
  if (!tbody) return;
  if (!rows?.length) {
    tbody.innerHTML = `<tr><td colspan="3" class="muted">No clubs match excluded nations.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map(
      (r) => `
    <tr>
      <td>
        <b>${escapeHtml(r.club_name || r.club_short_name)}</b><br>
        <small>${escapeHtml(r.club_short_name)}</small>
      </td>
      <td>${escapeHtml(r.nation || "—")}</td>
      <td>${r.has_owner ? "Yes" : "Vacant"}</td>
    </tr>`
    )
    .join("");
}

async function reloadLists() {
  setStatus("listStatus", "Loading…", true);
  const { data, error } = await supabase.rpc("admin_gpdb_exclusions_list", {
    p_season_id: seasonId(),
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("admin_gpdb_exclusions_list")
        ? "Run supabase/sql/patches/gpdb_season_exclusions.sql first."
        : error.message,
      false
    );
    return;
  }
  selectedSeasonId = data?.season_id ?? seasonId();
  const hint = document.getElementById("seasonHint");
  if (hint) {
    hint.textContent = `Lists for ${data?.season_label || `season ${selectedSeasonId}`}.`;
  }
  renderPlayers(data?.players || []);
  renderNations(data?.nations || []);
  renderManagers(data?.managers_from_nations || []);
  renderClubs(data?.clubs_from_nations || []);
  const mgrN = (data?.managers_from_nations || []).length;
  const clubN = (data?.clubs_from_nations || []).length;
  setStatus(
    "listStatus",
    `${(data?.players || []).length} player(s), ${(data?.nations || []).length} nation(s) excluded` +
      ` · ${mgrN} manager(s) / ${clubN} club(s) via those nations.`,
    true
  );
  await reloadActiveExclusions();
}

async function searchPlayers() {
  const q = document.getElementById("playerQuery")?.value?.trim() || "";
  const hits = document.getElementById("playerHits");
  if (!hits) return;
  if (q.length < 2) {
    hits.innerHTML = `<span class="muted">Type at least 2 characters.</span>`;
    return;
  }
  hits.textContent = "Searching…";
  const { data, error } = await supabase.rpc("admin_gpdb_search_players_for_exclusion", {
    p_query: q,
    p_limit: 25,
  });
  if (error) {
    hits.innerHTML = `<span class="muted">${escapeHtml(error.message)}</span>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    hits.innerHTML = `<span class="muted">No matches.</span>`;
    return;
  }
  hits.innerHTML = rows
    .map(
      (r) => `
    <div>
      <button type="button" class="button" data-add-player="${escapeHtml(r.player_id)}">
        Exclude ${escapeHtml(r.player_name)} (${escapeHtml(r.player_id)})
      </button>
      <span class="muted"> · ${escapeHtml(r.nation || "—")} · ${escapeHtml(
        r.position || "—"
      )} · OVR ${escapeHtml(r.rating ?? "—")}</span>
    </div>`
    )
    .join("");

  hits.querySelectorAll("[data-add-player]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const reason = document.getElementById("playerReason")?.value || null;
      try {
        const { error: err } = await supabase.rpc("admin_gpdb_exclude_player", {
          p_player_id: btn.dataset.addPlayer,
          p_reason: reason,
          p_season_id: seasonId(),
        });
        if (err) throw err;
        document.getElementById("playerReason").value = "";
        await reloadLists();
      } catch (e) {
        setStatus("listStatus", e.message || String(e), false);
      }
    });
  });
}

async function addNation() {
  const code = document.getElementById("nationSelect")?.value;
  if (!code) {
    setStatus("listStatus", "Select a nation first.", false);
    return;
  }
  const reason = document.getElementById("nationReason")?.value || null;
  try {
    const { error } = await supabase.rpc("admin_gpdb_exclude_nation", {
      p_nation_code: code,
      p_reason: reason,
      p_season_id: seasonId(),
    });
    if (error) throw error;
    document.getElementById("nationReason").value = "";
    await reloadLists();
  } catch (e) {
    setStatus("listStatus", e.message || String(e), false);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  try {
    await loadSeasons();
    await loadNations();
    await reloadLists();
  } catch (e) {
    setStatus("listStatus", e.message || String(e), false);
  }

  document.getElementById("reloadBtn")?.addEventListener("click", () => reloadLists());
  document.getElementById("seasonSelect")?.addEventListener("change", () => {
    syncCopyFromSelect();
    reloadLists();
  });
  document.getElementById("copyExclusionsBtn")?.addEventListener("click", () =>
    copyExclusionsFromSeason()
  );
  document.getElementById("playerSearchBtn")?.addEventListener("click", () => searchPlayers());
  document.getElementById("playerQuery")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      searchPlayers();
    }
  });
  document.getElementById("nationAddBtn")?.addEventListener("click", () => addNation());
});
