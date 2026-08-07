import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const XI_ORDER = ["GK", "LB", "CB1", "CB2", "RB", "LMF", "CMF", "RMF", "LWF", "CF", "RWF"];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadClubs();
  document.getElementById("clubSelect")?.addEventListener("change", onClubChanged);
  document.getElementById("previewBtn")?.addEventListener("click", () => runSet(true));
  document.getElementById("applyBtn")?.addEventListener("click", () => runSet(false));
});

async function loadClubs() {
  const sel = document.getElementById("clubSelect");
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error || !data?.length) {
    sel.innerHTML = '<option value="">Failed to load clubs</option>';
    return;
  }

  sel.innerHTML =
    '<option value="">Select club…</option>' +
    data
      .map(
        (c) =>
          `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(c.Club || c.ShortName)} (${escapeHtml(c.ShortName)})</option>`
      )
      .join("");
}

async function onClubChanged() {
  const box = document.getElementById("previewBox");
  if (box) {
    box.hidden = true;
    box.innerHTML = "";
  }
  const club = document.getElementById("clubSelect")?.value || "";
  if (!club) {
    const counts = document.getElementById("countsBox");
    if (counts) counts.hidden = true;
    return;
  }
  await loadSnapshot(club);
}

async function loadSnapshot(club) {
  setStatus("pageStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_test_matchday_squad_snapshot", {
    p_club_short_name: club,
  });

  if (error) {
    setStatus("pageStatus", `Snapshot failed: ${error.message}`);
    const counts = document.getElementById("countsBox");
    if (counts) {
      counts.hidden = false;
      counts.innerHTML = `<p style="color:#e88;">Run <code>admin_test_set_default_matchday_squad.sql</code> if this RPC is missing.</p>`;
    }
    return;
  }

  renderCounts(data);
  setStatus("pageStatus", data?.ok ? "" : data?.reason || "");
}

function renderCounts(snap) {
  const box = document.getElementById("countsBox");
  if (!box) return;
  if (!snap?.ok) {
    box.hidden = false;
    box.innerHTML = `<p style="color:#e88;">${escapeHtml(snap?.reason || "Failed")}</p>`;
    return;
  }

  box.hidden = false;
  box.innerHTML = `
    <div><strong>Contracted</strong> ${snap.contracted ?? 0}</div>
    <div style="margin-top:6px;">
      <strong>Saved matchday</strong>
      ${snap.has_saved_squad ? `${snap.matchday_pitch ?? 0} XI · ${snap.matchday_bench ?? 0} bench (${snap.matchday_total ?? 0} total)` : "none"}
      ${snap.formation_id ? ` · formation ${escapeHtml(snap.formation_id)}` : ""}
    </div>
    <p class="hint" style="margin:8px 0 0;">
      ${
        snap.can_set_default
          ? "Ready — needs at least 11 contracted players."
          : "Need at least 11 contracted players before a default squad can be set."
      }
    </p>
  `;
}

async function runSet(dryRun) {
  const club = document.getElementById("clubSelect")?.value || "";
  if (!club) {
    setStatus("pageStatus", "Select a club first.");
    return;
  }

  if (!dryRun) {
    const ok = window.confirm(
      `Set default Matchday squad for ${club}?\n\n` +
        `Overwrites any existing saved matchday XI/bench with a 4-3-3 best XI + bench.`
    );
    if (!ok) return;
  }

  setStatus("pageStatus", dryRun ? "Previewing…" : "Saving…");
  const { data, error } = await supabase.rpc("admin_test_set_default_matchday_squad", {
    p_club_short_name: club,
    p_dry_run: dryRun,
  });

  if (error) {
    setStatus("pageStatus", `Failed: ${error.message}`);
    return;
  }

  renderPreview(data);
  if (!dryRun && data?.ok) {
    await loadSnapshot(club);
    setStatus(
      "pageStatus",
      `Saved default squad: ${data.pitch ?? 0} XI + ${data.bench ?? 0} bench (${data.formation_id || "4-3-3"}).`
    );
  } else if (data?.ok) {
    setStatus(
      "pageStatus",
      `Preview: ${data.pitch ?? 0} XI + ${data.bench ?? 0} bench (${data.formation_id || "4-3-3"}).`
    );
  } else {
    setStatus("pageStatus", data?.reason || "Failed");
  }
}

function renderPreview(result) {
  const box = document.getElementById("previewBox");
  if (!box) return;

  if (!result?.ok) {
    box.hidden = false;
    box.innerHTML = `<p style="color:#e88;">${escapeHtml(result?.reason || "Failed")}</p>`;
    return;
  }

  const xi = Array.isArray(result.xi) ? [...result.xi] : [];
  xi.sort(
    (a, b) => XI_ORDER.indexOf(a.pitch_slot) - XI_ORDER.indexOf(b.pitch_slot)
  );
  const bench = Array.isArray(result.bench_players) ? result.bench_players : [];

  const xiRows = xi
    .map(
      (p) => `<tr>
        <td>${escapeHtml(p.pitch_slot)}</td>
        <td>${escapeHtml(p.player_name || p.player_id)}</td>
        <td>${escapeHtml(p.position || "")}</td>
        <td>${p.rating ?? "—"}</td>
      </tr>`
    )
    .join("");

  const benchRows = bench
    .map(
      (p) => `<tr>
        <td>B${p.sort_order ?? ""}</td>
        <td>${escapeHtml(p.player_name || p.player_id)}</td>
        <td>${escapeHtml(p.position || "")}</td>
        <td>${p.rating ?? "—"}</td>
      </tr>`
    )
    .join("");

  box.hidden = false;
  box.innerHTML = `
    <p>
      <b>${result.dry_run ? "Preview" : "Saved"}</b>
      · ${escapeHtml(result.formation_id || "4-3-3")}
      · ${result.pitch ?? 0} XI + ${result.bench ?? 0} bench
      · contracted ${result.contracted ?? "?"}
    </p>
    <h3 style="color:#ff9900;font-size:13px;margin:12px 0 6px;">Starting XI</h3>
    <table>
      <thead><tr><th>Slot</th><th>Player</th><th>Pos</th><th>R</th></tr></thead>
      <tbody>${xiRows || "<tr><td colspan=4>None</td></tr>"}</tbody>
    </table>
    <h3 style="color:#ff9900;font-size:13px;margin:14px 0 6px;">Bench</h3>
    <table>
      <thead><tr><th>#</th><th>Player</th><th>Pos</th><th>R</th></tr></thead>
      <tbody>${benchRows || "<tr><td colspan=4>None</td></tr>"}</tbody>
    </table>
  `;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
