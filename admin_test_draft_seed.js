import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

/** @type {object|null} */
let lastPreview = null;

const BAND_INPUTS = [
  { id: "bandLe65", key: "le65", label: "≤65" },
  { id: "bandR66_69", key: "r66_69", label: "66–69" },
  { id: "bandR70_72", key: "r70_72", label: "70–72" },
  { id: "bandR73_75", key: "r73_75", label: "73–75" },
  { id: "bandR76_78", key: "r76_78", label: "76–78" },
  { id: "bandR79", key: "r79", label: "79+" },
];

const POS_INPUTS = [
  { id: "posGk", key: "gk", label: "GK" },
  { id: "posDef", key: "def", label: "DEF" },
  { id: "posMid", key: "mid", label: "MID" },
  { id: "posFwd", key: "fwd", label: "FWD" },
];

const SETTINGS_STORAGE_KEY = "gpsl_draft_seed_settings";

const DEFAULT_SETTINGS = {
  minPlayersToBuy: 27,
  positionTargets: { gk: 2, def: 8, mid: 10, fwd: 8 },
  ratingBandTargets: { le65: 0, r66_69: 0, r70_72: 0, r73_75: 0, r76_78: 0, r79: 0 },
};

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  loadSettings();
  updateBandSumLine();
  updatePosSumLine();
  wireSettingsUi();

  await loadClubs();
  document.getElementById("previewBtn")?.addEventListener("click", () => runSeed(true));
  document.getElementById("placeBtn")?.addEventListener("click", () => runSeed(false));
});

function wireSettingsUi() {
  document.getElementById("minPlayersToBuy")?.addEventListener("input", updateBandSumLine);
  POS_INPUTS.forEach(({ id }) => {
    document.getElementById(id)?.addEventListener("input", updatePosSumLine);
  });
  BAND_INPUTS.forEach(({ id }) => {
    document.getElementById(id)?.addEventListener("input", updateBandSumLine);
  });

  document.getElementById("saveMinPlayersBtn")?.addEventListener("click", saveMinPlayersSetting);
  document.getElementById("savePosBtn")?.addEventListener("click", savePositionChartSetting);
  document.getElementById("saveBandsBtn")?.addEventListener("click", saveBandTargetsSetting);
  document.getElementById("spreadBandsBtn")?.addEventListener("click", (e) => {
    e.preventDefault();
    spreadBandsEvenly();
  });
}

function readMinPlayers() {
  const raw = Number(document.getElementById("minPlayersToBuy")?.value);
  if (!Number.isFinite(raw)) return DEFAULT_SETTINGS.minPlayersToBuy;
  return Math.max(1, Math.min(27, Math.trunc(raw)));
}

function readRatingBandTargets() {
  const targets = {};
  for (const { id, key } of BAND_INPUTS) {
    targets[key] = Math.max(0, Number(document.getElementById(id)?.value || 0));
  }
  return targets;
}

function readPositionTargets() {
  const targets = {};
  for (const { id, key } of POS_INPUTS) {
    targets[key] = Math.max(0, Number(document.getElementById(id)?.value || 0));
  }
  return targets;
}

function hasRatingBandTargets(targets) {
  return Object.values(targets).some((n) => n > 0);
}

function readSettingsFromStorage() {
  try {
    const raw = localStorage.getItem(SETTINGS_STORAGE_KEY);
    if (raw) {
      const saved = JSON.parse(raw);
      return {
        minPlayersToBuy: saved.minPlayersToBuy ?? DEFAULT_SETTINGS.minPlayersToBuy,
        positionTargets: { ...DEFAULT_SETTINGS.positionTargets, ...(saved.positionTargets || {}) },
        ratingBandTargets: { ...DEFAULT_SETTINGS.ratingBandTargets, ...(saved.ratingBandTargets || {}) },
      };
    }

    // Migrate legacy keys from earlier builds.
    const legacyBands = localStorage.getItem("gpsl_draft_seed_rating_bands");
    const legacyPos = localStorage.getItem("gpsl_draft_seed_position_chart");
    const migrated = { ...DEFAULT_SETTINGS };
    if (legacyPos) {
      migrated.positionTargets = {
        ...migrated.positionTargets,
        ...JSON.parse(legacyPos),
      };
    }
    if (legacyBands) {
      migrated.ratingBandTargets = {
        ...migrated.ratingBandTargets,
        ...JSON.parse(legacyBands),
      };
    }
    if (legacyBands || legacyPos) {
      writeSettings(migrated);
    }
    return migrated;
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function readSettingsFromDom() {
  return {
    minPlayersToBuy: readMinPlayers(),
    positionTargets: readPositionTargets(),
    ratingBandTargets: readRatingBandTargets(),
  };
}

function writeSettings(settings) {
  localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
}

function loadSettings() {
  const settings = readSettingsFromStorage();
  const minEl = document.getElementById("minPlayersToBuy");
  if (minEl) minEl.value = String(settings.minPlayersToBuy);

  for (const { id, key } of POS_INPUTS) {
    const el = document.getElementById(id);
    if (el && settings.positionTargets[key] != null) {
      el.value = String(settings.positionTargets[key]);
    }
  }

  for (const { id, key } of BAND_INPUTS) {
    const el = document.getElementById(id);
    if (el && settings.ratingBandTargets[key] != null) {
      el.value = String(settings.ratingBandTargets[key]);
    }
  }
}

function setSettingsNote(id, message) {
  const el = document.getElementById(id);
  if (el) el.textContent = message;
}

function saveMinPlayersSetting() {
  const settings = readSettingsFromStorage();
  settings.minPlayersToBuy = readMinPlayers();
  writeSettings(settings);
  setSettingsNote("minPlayersSaveNote", `Saved: ${settings.minPlayersToBuy} players.`);
  updateBandSumLine();
}

function savePositionChartSetting() {
  const settings = readSettingsFromStorage();
  settings.positionTargets = readPositionTargets();
  writeSettings(settings);
  const t = settings.positionTargets;
  setSettingsNote(
    "posSaveNote",
    `Saved: GK ${t.gk} · DEF ${t.def} · MID ${t.mid} · FWD ${t.fwd}.`
  );
  updatePosSumLine();
}

function saveBandTargetsSetting() {
  const settings = readSettingsFromStorage();
  settings.ratingBandTargets = readRatingBandTargets();
  writeSettings(settings);
  const sum = Object.values(settings.ratingBandTargets).reduce((a, b) => a + b, 0);
  setSettingsNote("bandsSaveNote", `Saved rating bands (total ${sum}).`);
  updateBandSumLine();
}

function updateBandSumLine() {
  const targets = readRatingBandTargets();
  const sum = Object.values(targets).reduce((a, b) => a + b, 0);
  const minPlayers = readMinPlayers();
  const el = document.getElementById("bandSumLine");
  if (!el) return;
  const warn =
    sum > 0 && minPlayers > 0 && sum !== minPlayers
      ? ` · mismatch with min players (${minPlayers})`
      : "";
  el.textContent = `Band total: ${sum}${warn}`;
}

function updatePosSumLine() {
  const targets = readPositionTargets();
  const sum = Object.values(targets).reduce((a, b) => a + b, 0);
  const el = document.getElementById("posSumLine");
  if (!el) return;
  el.textContent = `Position chart total: ${sum}`;
}

function spreadBandsEvenly() {
  const total = readMinPlayers();
  if (total < 1) {
    setSettingsNote("bandsSaveNote", "Set minimum players to buy (1–27) first.");
    return;
  }

  const base = Math.floor(total / BAND_INPUTS.length);
  const rem = total % BAND_INPUTS.length;
  const values = [];

  BAND_INPUTS.forEach(({ id, label }, i) => {
    const val = base + (i < rem ? 1 : 0);
    values.push(`${label} ${val}`);
    const el = document.getElementById(id);
    if (el) {
      el.value = String(val);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
  });

  updateBandSumLine();
  setSettingsNote(
    "bandsSaveNote",
    `Spread ${total}: ${values.join(" · ")}. Click Save rating bands to keep.`
  );
}

function ratingBandLine(actual, targets) {
  if (!targets || !actual) return "";
  const bits = BAND_INPUTS.map(({ key, label }) => {
    const tgt = targets[key] ?? 0;
    const got = actual[key] ?? 0;
    if (tgt <= 0) return null;
    const ok = got >= tgt;
    return `${label} ${ok ? "✓" : "⚠"} ${got}/${tgt}`;
  }).filter(Boolean);
  if (!bits.length) return "";
  const allOk = bits.every((b) => b.includes("✓"));
  return `<span class="${allOk ? "compliance-ok" : "compliance-warn"}">Rating bands: ${bits.join(" · ")}</span>`;
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

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function complianceLine(proj, targets) {
  const hgOk = (proj.home_grown ?? 0) >= (targets.min_hg ?? 8);
  const u21Ok = (proj.under_21 ?? 0) >= (targets.min_u21 ?? 5);
  const starOk = (proj.stars ?? 0) >= Math.min(targets.star_cap ?? 2, 2);
  const cls = hgOk && u21Ok && starOk ? "compliance-ok" : "compliance-warn";
  const bits = [
    `HG ${hgOk ? "✓" : "⚠"} ${proj.home_grown ?? 0}/${targets.min_hg ?? 8}`,
    `U21 ${u21Ok ? "✓" : "⚠"} ${proj.under_21 ?? 0}/${targets.min_u21 ?? 5}`,
    `Stars ${starOk ? "✓" : "⚠"} ${proj.stars ?? 0}/${targets.star_cap ?? "—"} (≥${targets.star_min_rating ?? 79})`,
  ];
  return `<span class="${cls}">${bits.join(" · ")}</span>`;
}

function renderPreview(result) {
  const box = document.getElementById("previewBox");
  if (!box) return;

  if (!result?.ok) {
    box.hidden = false;
    box.innerHTML = `<p style="color:#e88;">${escapeHtml(result?.reason || "Preview failed")}</p>`;
    return;
  }

  const proj = result.projected_after || {};
  const pos = proj.positions || {};
  const targets = proj.targets || {};
  const posTargets = result.position_targets || {
    gk: targets.gk,
    def: targets.def,
    mid: targets.mid,
    fwd: targets.fwd,
  };
  const bids = Array.isArray(result.bids) ? result.bids : [];
  const skipped = Array.isArray(result.skipped) ? result.skipped : [];
  const avgBid = bids.length ? (result.total_spend || 0) / bids.length : 0;
  const squadBefore = result.squad_size_before ?? result.composition_before?.total ?? null;
  const spareSlots = result.spare_squad_slots;
  const capNote = result.squad_size_cap_note;
  const requestedMin = result.min_players_requested;
  const effectiveTarget = result.min_players_target;
  const bandTargets = result.rating_band_targets || targets.rating_bands || {};
  const bandActual = result.rating_band_new_signings || proj.rating_bands || {};
  const bandLine = ratingBandLine(bandActual, bandTargets);

  box.hidden = false;
  box.innerHTML = `
    <p><b>${escapeHtml(result.club)}</b> · ${result.dry_run ? "Preview" : "Placed"} ·
      ${result.dry_run ? bids.length : result.placed} bid(s)${effectiveTarget != null ? ` · target ≥ ${effectiveTarget}` : ""}${result.min_players_met === false ? " · <span style=\"color:#e8c547\">below minimum</span>" : ""} ·
      spend ${formatMoney(result.total_spend || 0)} (market value)${avgBid > 0 ? ` · avg ${formatMoney(avgBid)}` : ""} ·
      club balance ${formatMoney(result.balance || 0)} ·
      draft credits after ${result.draft_credits_remaining ?? "—"}</p>
    ${
      squadBefore != null || spareSlots != null
        ? `<p>Squad now: <b>${squadBefore ?? "—"}</b>/28 · spare slots: <b>${spareSlots ?? "—"}</b>${
            requestedMin != null ? ` · requested min: ${requestedMin}` : ""
          }${effectiveTarget != null && requestedMin != null && effectiveTarget < requestedMin ? ` · effective target: <b>${effectiveTarget}</b>` : ""}</p>`
        : ""
    }
    ${
      capNote
        ? `<p style="color:#e8c547;"><b>Cap:</b> ${escapeHtml(capNote)}</p>`
        : ""
    }
    <p>Projected squad: <b>${proj.squad_size ?? "—"}</b> players ·
      GK ${pos.gk ?? 0}/${posTargets.gk ?? 2} · DEF ${pos.def ?? 0}/${posTargets.def ?? 8} ·
      MID ${pos.mid ?? 0}/${posTargets.mid ?? 10} · FWD ${pos.fwd ?? 0}/${posTargets.fwd ?? 8}</p>
    <p>Compliance: ${complianceLine(proj, targets)}</p>
    ${bandLine ? `<p>${bandLine}</p>` : ""}
    ${
      bids.length
        ? `<table>
      <thead><tr><th>Player</th><th>Pos</th><th>Rtg</th><th>MV bid</th><th>Tags</th></tr></thead>
      <tbody>${bids
        .map((b) => {
          const tags = [];
          if (b.is_star) tags.push('<span class="tag tag-star">STAR</span>');
          if (b.home_grown) tags.push('<span class="tag tag-hg">HG</span>');
          if (b.under_21) tags.push('<span class="tag tag-u21">U21</span>');
          tags.push('<span class="tag tag-open">OPEN</span>');
          return `<tr>
            <td>${escapeHtml(b.player_name)}</td>
            <td>${escapeHtml(b.position || b.pos_group || "—")}</td>
            <td>${escapeHtml(b.rating ?? "—")}</td>
            <td>${formatMoney(b.amount)}</td>
            <td>${tags.join("") || "—"}</td>
          </tr>`;
        })
        .join("")}</tbody></table>`
        : "<p>No bids planned.</p>"
    }
    ${
      skipped.length
        ? `<p style="margin-top:10px;color:#aaa;">Skipped: ${skipped
            .map((s) => {
              const bits = [s.reason];
              if (s.player_name) bits.push(s.player_name);
              if (s.still_needed != null) bits.push(`needed ${s.still_needed}`);
              return escapeHtml(bits.join(" · "));
            })
            .join("; ")}</p>`
        : ""
    }`;
}

async function runSeed(dryRun) {
  const club = document.getElementById("clubSelect")?.value?.trim();
  const minPlayersToBuy = readMinPlayers();
  const ratingBandTargets = readRatingBandTargets();
  const positionTargets = readPositionTargets();

  if (!club) {
    setStatus("pageStatus", "Select a club first.", false);
    return;
  }

  if (!dryRun) {
    if (
      !confirm(
        `Place at least ${minPlayersToBuy} draft bid(s) for ${club} at market value?\n\n` +
          `This opens real GPDB draft auctions. Settlement happens at random finish — not instant signings.\n\n` +
          (lastPreview?.total_spend
            ? `Preview spend: ${formatMoney(lastPreview.total_spend)}`
            : "Run Preview first to see the plan.")
      )
    ) {
      return;
    }
  }

  setStatus("pageStatus", dryRun ? "Building preview…" : "Placing bids…");

  const { data, error } = await supabase.rpc("admin_compliance_draft_seed_bids", {
    p_club_short_name: club,
    p_min_players_to_buy: minPlayersToBuy,
    p_dry_run: dryRun,
    p_rating_band_targets: hasRatingBandTargets(ratingBandTargets) ? ratingBandTargets : null,
    p_position_targets: positionTargets,
  });

  if (error) {
    setStatus(
      "pageStatus",
      `❌ ${error.message}. Run supabase/sql/patches/admin_compliance_draft_seed.sql in Supabase.`,
      false
    );
    return;
  }

  if (!data?.ok) {
    const reason = data?.reason || "failed";
    const hints = {
      draft_not_enabled: "Enable player draft in Admin → Transfers.",
      draft_not_scheduled: "Set draft auction start time.",
      draft_not_started: "Draft has not started yet.",
      draft_ended: "Draft bidding has ended.",
      new_auction_locked_after_cutoff: "New draft auctions are locked after the 23-hour cutoff.",
      squad_full: `Squad already at ${data?.squad_size ?? 28} players.`,
    };
    setStatus("pageStatus", `❌ ${hints[reason] || reason}`, false);
    renderPreview(data);
    return;
  }

  lastPreview = data;
  renderPreview(data);

  if (dryRun) {
    const met = data.min_players_met !== false ? "" : " (below minimum target)";
    setStatus(
      "pageStatus",
      `✅ Preview: ${data.planned_bids ?? 0} bid(s) at market value, ${formatMoney(data.total_spend || 0)} total${met}.`
    );
  } else {
    setStatus(
      "pageStatus",
      `✅ Placed ${data.placed ?? 0} draft bid(s) for ${club}. Check GPDB / Player Draft Auctions.`
    );
  }
}
