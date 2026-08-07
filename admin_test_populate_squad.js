import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

const DEFAULT_POS = { gk: 2, def: 8, mid: 8, fwd: 6 };
const POS_INPUTS = [
  { id: "posGk", key: "gk" },
  { id: "posDef", key: "def" },
  { id: "posMid", key: "mid" },
  { id: "posFwd", key: "fwd" },
];

/** Preview top→bottom order (exact Position codes). */
const POSITION_SORT_ORDER = [
  "GK",
  "LB",
  "CB",
  "RB",
  "DMF",
  "LMF",
  "CMF",
  "RMF",
  "LWF",
  "SS",
  "RWF",
  "CF",
];

/** @type {object|null} */
let lastSnapshot = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  resetPositionMins();
  wireUi();
  await loadClubs();
});

function wireUi() {
  document.getElementById("clubSelect")?.addEventListener("change", onClubChanged);
  POS_INPUTS.forEach(({ id }) => {
    document.getElementById(id)?.addEventListener("input", updatePosSumLine);
  });
  document.getElementById("resetPosBtn")?.addEventListener("click", () => {
    resetPositionMins();
    setStatus("pageStatus", "Position mins reset to defaults.");
  });
  document.getElementById("previewBtn")?.addEventListener("click", () => runPopulate(true));
  document.getElementById("populateBtn")?.addEventListener("click", () => runPopulate(false));
}

function resetPositionMins() {
  for (const { id, key } of POS_INPUTS) {
    const el = document.getElementById(id);
    if (el) el.value = String(DEFAULT_POS[key]);
  }
  updatePosSumLine();
}

function readPositionTargets() {
  const targets = {};
  for (const { id, key } of POS_INPUTS) {
    targets[key] = Math.max(0, Math.min(24, Math.trunc(Number(document.getElementById(id)?.value || 0))));
  }
  return targets;
}

function updatePosSumLine() {
  const t = readPositionTargets();
  const sum = t.gk + t.def + t.mid + t.fwd;
  const el = document.getElementById("posSumLine");
  if (!el) return;
  const warn = sum > 24 ? " — exceeds 24 (blocked)." : sum < 24 ? " — remaining slots filled without position preference." : "";
  el.textContent = `Position mins total: ${sum} / 24${warn}`;
  el.style.color = sum > 24 ? "#e88" : "#888";
}

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
  resetPositionMins();
  lastSnapshot = null;
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
  setStatus("pageStatus", "Loading squad…");
  const { data, error } = await supabase.rpc("admin_test_squad_snapshot", {
    p_club_short_name: club,
  });

  if (error) {
    setStatus("pageStatus", `Snapshot failed: ${error.message}`);
    const counts = document.getElementById("countsBox");
    if (counts) {
      counts.hidden = false;
      counts.innerHTML = `<p style="color:#e88;">Run <code>admin_test_populate_squad.sql</code> if this RPC is missing.</p>`;
    }
    return;
  }

  lastSnapshot = data;
  renderCounts(data);
  setStatus("pageStatus", data?.ok ? "" : data?.reason || "Snapshot failed");
}

function renderCounts(snap) {
  const box = document.getElementById("countsBox");
  if (!box) return;
  if (!snap?.ok) {
    box.hidden = false;
    box.innerHTML = `<p style="color:#e88;">${escapeHtml(snap?.reason || "Failed")}</p>`;
    return;
  }

  const pos = snap.positions || {};
  const total = snap.total ?? 0;
  const need = Math.max(0, 24 - total);
  const hgOk = (snap.home_grown ?? 0) >= (snap.min_home_grown ?? 8);
  const u21Ok = (snap.under_21 ?? 0) >= (snap.min_under_21 ?? 5);
  const stars = snap.stars ?? 0;
  const starCap = snap.star_cap ?? 0;
  const starOk = stars >= starCap;

  box.hidden = false;
  box.innerHTML = `
    <div class="row">
      <span><strong>Squad</strong> ${total} / 24 (${need} to fill)</span>
      <span><strong>Balance</strong> ${formatMoney(snap.balance ?? 0)}</span>
    </div>
    <div class="row" style="margin-top:8px;">
      <span>GK ${pos.gk ?? 0}</span>
      <span>DEF ${pos.def ?? 0}</span>
      <span>MID ${pos.mid ?? 0}</span>
      <span>FWD ${pos.fwd ?? 0}</span>
      ${(pos.other ?? 0) > 0 ? `<span>Other ${pos.other}</span>` : ""}
    </div>
    <div class="row" style="margin-top:8px;">
      <span class="${hgOk ? "compliance-ok" : "compliance-warn"}">
        HG ${hgOk ? "✓" : "⚠"} ${snap.home_grown ?? 0}/${snap.min_home_grown ?? 8}
      </span>
      <span class="${u21Ok ? "compliance-ok" : "compliance-warn"}">
        U21 ${u21Ok ? "✓" : "⚠"} ${snap.under_21 ?? 0}/${snap.min_under_21 ?? 5}
      </span>
      <span class="${starOk ? "compliance-ok" : "compliance-warn"}">
        Stars ${starOk ? "✓" : "⚠"} ${stars}/${starCap} (quota, ≥${snap.star_min_rating ?? 79})
      </span>
    </div>
  `;
}

async function runPopulate(dryRun) {
  const club = document.getElementById("clubSelect")?.value || "";
  if (!club) {
    setStatus("pageStatus", "Select a club first.");
    return;
  }

  const targets = readPositionTargets();
  const sum = targets.gk + targets.def + targets.mid + targets.fwd;
  if (sum > 24) {
    setStatus("pageStatus", "Position mins cannot exceed 24.");
    return;
  }

  if (!dryRun) {
    const ok = window.confirm(
      `Populate ${club} up to 24 players at market value?\n\n` +
        `This posts real transfer ledger lines (Central Bank) and contracts.\n` +
        `Mins: GK ${targets.gk} · DEF ${targets.def} · MID ${targets.mid} · FWD ${targets.fwd}`
    );
    if (!ok) return;
  }

  setStatus("pageStatus", dryRun ? "Previewing…" : "Populating…");
  const { data, error } = await supabase.rpc("admin_test_populate_squad", {
    p_club_short_name: club,
    p_dry_run: dryRun,
    p_position_targets: targets,
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
      `Signed ${data.placed ?? 0} player(s). Spend ${formatMoney(data.total_spend ?? 0)}. Squad now ${data.squad_size_after ?? "?"} / 24.`
    );
  } else if (data?.ok) {
    setStatus(
      "pageStatus",
      `Preview: ${data.planned ?? data.placed ?? 0} signing(s), spend ${formatMoney(data.total_spend ?? 0)}.`
    );
  } else {
    setStatus("pageStatus", data?.reason || "Failed");
  }
}

function complianceLine(proj) {
  const targets = proj?.targets || {};
  const pos = proj?.positions || {};
  const hgOk = (proj?.home_grown ?? 0) >= (targets.min_hg ?? 8);
  const u21Ok = (proj?.under_21 ?? 0) >= (targets.min_u21 ?? 5);
  const stars = proj?.stars ?? 0;
  const starCap = targets.star_cap ?? proj?.star_cap ?? 0;
  const starOk = stars >= starCap;
  const gkOk = (pos.gk ?? 0) >= (targets.gk ?? 0);
  const defOk = (pos.def ?? 0) >= (targets.def ?? 0);
  const midOk = (pos.mid ?? 0) >= (targets.mid ?? 0);
  const fwdOk = (pos.fwd ?? 0) >= (targets.fwd ?? 0);
  const allOk = hgOk && u21Ok && starOk && gkOk && defOk && midOk && fwdOk;
  const bits = [
    `HG ${hgOk ? "✓" : "⚠"} ${proj?.home_grown ?? 0}/${targets.min_hg ?? 8}`,
    `U21 ${u21Ok ? "✓" : "⚠"} ${proj?.under_21 ?? 0}/${targets.min_u21 ?? 5}`,
    `Stars ${starOk ? "✓" : "⚠"} ${stars}/${starCap} (quota)`,
    `GK ${gkOk ? "✓" : "⚠"} ${pos.gk ?? 0}/${targets.gk ?? 0}`,
    `DEF ${defOk ? "✓" : "⚠"} ${pos.def ?? 0}/${targets.def ?? 0}`,
    `MID ${midOk ? "✓" : "⚠"} ${pos.mid ?? 0}/${targets.mid ?? 0}`,
    `FWD ${fwdOk ? "✓" : "⚠"} ${pos.fwd ?? 0}/${targets.fwd ?? 0}`,
  ];
  return `<span class="${allOk ? "compliance-ok" : "compliance-warn"}">${bits.join(" · ")}</span>`;
}

function positionSortKey(position) {
  const code = String(position ?? "")
    .trim()
    .toUpperCase();
  const idx = POSITION_SORT_ORDER.indexOf(code);
  return idx >= 0 ? idx : 1000;
}

function sortSignedByPosition(signed) {
  return [...signed].sort((a, b) => {
    const pa = positionSortKey(a.position);
    const pb = positionSortKey(b.position);
    if (pa !== pb) return pa - pb;
    return String(a.player_name || "").localeCompare(String(b.player_name || ""));
  });
}

function renderPreview(result) {
  const box = document.getElementById("previewBox");
  if (!box) return;

  if (!result?.ok) {
    box.hidden = false;
    box.innerHTML = `<p style="color:#e88;">${escapeHtml(result?.reason || "Failed")}</p>`;
    return;
  }

  const signed = sortSignedByPosition(Array.isArray(result.signed) ? result.signed : []);
  const skipped = Array.isArray(result.skipped) ? result.skipped : [];
  const proj = result.projected_after || {};
  const posT = result.position_targets || {};
  const regOk = result.registration_met !== false;

  const rows = signed
    .map((p) => {
      const tags = [
        p.home_grown ? '<span class="tag tag-hg">HG</span>' : "",
        p.under_21 ? '<span class="tag tag-u21">U21</span>' : "",
        p.is_star ? '<span class="tag tag-star">★</span>' : "",
      ].join("");
      return `<tr>
        <td>${escapeHtml(p.player_name || p.player_id)}</td>
        <td>${escapeHtml(p.position || p.pos_group || "")}</td>
        <td>${p.rating ?? "—"}</td>
        <td>${p.age ?? "—"}</td>
        <td>${tags}</td>
        <td>${formatMoney(p.fee ?? p.market_value ?? 0)}</td>
      </tr>`;
    })
    .join("");

  box.hidden = false;
  box.innerHTML = `
    <p>
      <b>${result.dry_run ? "Preview" : "Signed"}</b>
      · ${signed.length} player(s)
      · ${result.squad_size_before ?? "?"} → ${result.squad_size_after ?? "?"} / 24
      · spend ${formatMoney(result.total_spend ?? 0)}
      · balance ${formatMoney(result.balance_before ?? 0)} → ${formatMoney(result.balance_after ?? 0)}
    </p>
    <p>Position mins used: GK ${posT.gk ?? "—"} · DEF ${posT.def ?? "—"} · MID ${posT.mid ?? "—"} · FWD ${posT.fwd ?? "—"}</p>
    <p>${complianceLine(proj)}</p>
    ${
      regOk
        ? ""
        : `<p class="compliance-warn"><b>Registration not met</b> — projected squad is still short of HG / U21 / star quota / position mins. Re-run SQL patch if this keeps happening on an empty club.</p>`
    }
    ${
      signed.length
        ? `<table>
            <thead><tr><th>Player</th><th>Pos</th><th>R</th><th>Age</th><th></th><th>Fee</th></tr></thead>
            <tbody>${rows}</tbody>
          </table>`
        : `<p class="hint">${escapeHtml(result.reason === "already_at_24" ? "Already at 24 players." : "No signings planned.")}</p>`
    }
    ${
      skipped.length
        ? `<p class="compliance-warn" style="margin-top:10px;">Skipped / notes: ${skipped.length}</p>
           <ul>${skipped
             .slice(0, 12)
             .map(
               (s) =>
                 `<li>${escapeHtml(s.reason || "note")}${s.detail ? ": " + escapeHtml(s.detail) : ""}${
                   s.player_name ? " (" + escapeHtml(s.player_name) + ")" : ""
                 }</li>`
             )
             .join("")}</ul>`
        : ""
    }
  `;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
