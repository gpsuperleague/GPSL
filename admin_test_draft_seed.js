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

const BAND_STORAGE_KEY = "gpsl_draft_seed_rating_bands";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  loadBandTargets();
  updateBandSumLine();
  BAND_INPUTS.forEach(({ id }) => {
    document.getElementById(id)?.addEventListener("input", () => {
      updateBandSumLine();
      saveBandTargets();
    });
  });
  document.getElementById("minPlayersToBuy")?.addEventListener("input", updateBandSumLine);
  document.getElementById("spreadBandsBtn").onclick = spreadBandsEvenly;

  await loadClubs();
  document.getElementById("previewBtn").onclick = () => runSeed(true);
  document.getElementById("placeBtn").onclick = () => runSeed(false);
});

function readRatingBandTargets() {
  const targets = {};
  for (const { id, key } of BAND_INPUTS) {
    targets[key] = Math.max(0, Number(document.getElementById(id)?.value || 0));
  }
  return targets;
}

function hasRatingBandTargets(targets) {
  return Object.values(targets).some((n) => n > 0);
}

function loadBandTargets() {
  try {
    const raw = localStorage.getItem(BAND_STORAGE_KEY);
    if (!raw) return;
    const saved = JSON.parse(raw);
    for (const { id, key } of BAND_INPUTS) {
      const el = document.getElementById(id);
      if (el && saved[key] != null) el.value = String(saved[key]);
    }
  } catch {
    /* ignore */
  }
}

function saveBandTargets() {
  try {
    localStorage.setItem(BAND_STORAGE_KEY, JSON.stringify(readRatingBandTargets()));
  } catch {
    /* ignore */
  }
}

function updateBandSumLine() {
  const targets = readRatingBandTargets();
  const sum = Object.values(targets).reduce((a, b) => a + b, 0);
  const minPlayers = Number(document.getElementById("minPlayersToBuy")?.value || 0);
  const el = document.getElementById("bandSumLine");
  if (!el) return;
  const warn =
    sum > 0 && minPlayers > 0 && sum !== minPlayers
      ? ` · <span style="color:#e8c547">band total (${sum}) ≠ min players (${minPlayers})</span>`
      : "";
  el.innerHTML = `Band total: ${sum}${warn}`;
}

function spreadBandsEvenly() {
  const total = Math.max(0, Number(document.getElementById("minPlayersToBuy")?.value || 27));
  const base = Math.floor(total / BAND_INPUTS.length);
  const rem = total % BAND_INPUTS.length;
  BAND_INPUTS.forEach(({ id }, i) => {
    const el = document.getElementById(id);
    if (el) el.value = String(base + (i < rem ? 1 : 0));
  });
  updateBandSumLine();
  saveBandTargets();
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
  const bids = Array.isArray(result.bids) ? result.bids : [];
  const skipped = Array.isArray(result.skipped) ? result.skipped : [];
  const totalBudget = Number(document.getElementById("totalSpendBudget")?.value || 0);
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
      spend ${formatMoney(result.total_spend || 0)}${totalBudget > 0 ? ` / ${formatMoney(totalBudget)} cap` : ""}${avgBid > 0 ? ` · avg ${formatMoney(avgBid)}` : ""} ·
      balance ${formatMoney(result.balance || 0)} ·
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
      GK ${pos.gk ?? 0}/${targets.gk ?? 2} · DEF ${pos.def ?? 0}/${targets.def ?? 8} ·
      MID ${pos.mid ?? 0}/${targets.mid ?? 10} · FWD ${pos.fwd ?? 0}/${targets.fwd ?? 8}</p>
    <p>Compliance: ${complianceLine(proj, targets)}</p>
    ${bandLine ? `<p>${bandLine}</p>` : ""}
    ${
      bids.length
        ? `<table>
      <thead><tr><th>Player</th><th>Pos</th><th>Rtg</th><th>Bid</th><th>Type</th><th>Tags</th></tr></thead>
      <tbody>${bids
        .map((b) => {
          const tags = [];
          if (b.is_star) tags.push('<span class="tag tag-star">STAR</span>');
          if (b.home_grown) tags.push('<span class="tag tag-hg">HG</span>');
          if (b.under_21) tags.push('<span class="tag tag-u21">U21</span>');
          const type =
            b.bid_type === "open"
              ? '<span class="tag tag-open">OPEN</span>'
              : '<span class="tag tag-join">JOIN</span>';
          return `<tr>
            <td>${escapeHtml(b.player_name)}</td>
            <td>${escapeHtml(b.position || b.pos_group || "—")}</td>
            <td>${escapeHtml(b.rating ?? "—")}</td>
            <td>${formatMoney(b.amount)}</td>
            <td>${type}</td>
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
              if (s.remaining_budget != null) bits.push(`left ${formatMoney(s.remaining_budget)}`);
              if (s.afford_cap != null) bits.push(`cap ${formatMoney(s.afford_cap)}`);
              if (s.still_needed != null) bits.push(`needed ${s.still_needed}`);
              return escapeHtml(bits.join(" · "));
            })
            .join("; ")}</p>`
        : ""
    }`;
}

async function runSeed(dryRun) {
  const club = document.getElementById("clubSelect")?.value?.trim();
  const minPlayersToBuy = Number(document.getElementById("minPlayersToBuy")?.value || 27);
  const budgetReserve = Number(document.getElementById("budgetReserve")?.value || 0);
  const totalSpendRaw = document.getElementById("totalSpendBudget")?.value;
  const totalSpendBudget =
    totalSpendRaw === "" || totalSpendRaw == null ? null : Number(totalSpendRaw);
  const ratingBandTargets = readRatingBandTargets();

  if (!club) {
    setStatus("pageStatus", "Select a club first.", false);
    return;
  }

  if (!dryRun) {
    if (
      !confirm(
        `Place at least ${minPlayersToBuy} draft bid(s) for ${club}?\n\n` +
          `This opens/joins real GPDB draft auctions. Settlement happens at random finish — not instant signings.\n\n` +
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
    p_budget_reserve: budgetReserve,
    p_dry_run: dryRun,
    p_total_spend_budget: totalSpendBudget,
    p_rating_band_targets: hasRatingBandTargets(ratingBandTargets) ? ratingBandTargets : null,
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
      `✅ Preview: ${data.planned_bids ?? 0} bid(s), ${formatMoney(data.total_spend || 0)} total${met}.`
    );
  } else {
    setStatus(
      "pageStatus",
      `✅ Placed ${data.placed ?? 0} draft bid(s) for ${club}. Check GPDB / Player Draft Auctions.`
    );
  }
}
