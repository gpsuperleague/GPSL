import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

/** @type {object|null} */
let lastPreview = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadClubs();
  document.getElementById("previewBtn").onclick = () => runSeed(true);
  document.getElementById("placeBtn").onclick = () => runSeed(false);
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
