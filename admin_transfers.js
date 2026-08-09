import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  loadGlobalSettings,
  computeNextDraftTimesFromNow,
  computeLateDraftStartNow,
  isDraftScheduleExpired,
  isPastNominalDraftStartUk,
} from "./global.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  await loadSettings();
  document.getElementById("saveSettingsBtn").onclick = saveSettings;
  document.getElementById("resetDraftBtn").onclick = resetDraftSchedule;
  document.getElementById("lateStartDraftBtn")?.addEventListener("click", lateStartDraftSchedule);
  document.getElementById("runTransferEngineBtn").onclick = runTransferEngine;
  document.getElementById("settlePlayerDraftsBtn").onclick = forceSettlePlayerDrafts;
  document.getElementById("settleManagerDraftsBtn").onclick = settleManagerDraftsNow;
  document.getElementById("seedClubAuctionBtn").onclick = seedClubAuctionListings;
  document.getElementById("settleClubAuctionsBtn").onclick = settleClubAuctionsNow;
  document.getElementById("cancelPreviewBtn").onclick = previewCancelOpenTransfers;
  document.getElementById("cancelExecuteBtn").onclick = executeCancelOpenTransfers;

  const hash = (window.location.hash || "").replace("#", "");
  if (hash) {
    document.getElementById(hash)?.scrollIntoView({ behavior: "smooth", block: "start" });
  }
});

function cancelOpenParams() {
  const listingRaw = document.getElementById("cancelListingId")?.value?.trim();
  const listingId = listingRaw ? Number(listingRaw) : null;
  return {
    p_scope: document.getElementById("cancelScope")?.value || "all",
    p_listing_id: Number.isFinite(listingId) && listingId > 0 ? listingId : null,
    p_player_id: document.getElementById("cancelPlayerId")?.value?.trim() || null,
    p_seller_club: document.getElementById("cancelSellerClub")?.value?.trim() || null,
    p_manager_id: document.getElementById("cancelManagerId")?.value?.trim() || null,
  };
}

function formatCancelPreview(data) {
  if (!data) return "No preview data.";
  const lines = [
    `Scope: ${data.scope}`,
    `Market listings: ${data.market_listings ?? 0} (bids: ${data.market_bids ?? 0})`,
    `Player draft listings: ${data.draft_listings ?? 0} (bids: ${data.draft_bids ?? 0})`,
    `Direct offers: ${data.direct_offers ?? 0}`,
    `Manager draft listings: ${data.manager_draft_listings ?? 0} (bids: ${data.manager_draft_bids ?? 0})`,
    `Perpetual / underperformance listings in match: ${data.perpetual_renew_listings ?? 0}`,
    `Total listings/offers: ${data.total_items ?? 0}`,
  ];
  return lines.join("\n");
}

async function previewCancelOpenTransfers() {
  setStatus("cancelStatus", "Loading preview…");
  const out = document.getElementById("cancelPreviewOut");
  try {
    const { data, error } = await supabase.rpc(
      "admin_cancel_open_transfers_preview",
      cancelOpenParams()
    );
    if (error) throw error;
    if (out) out.textContent = formatCancelPreview(data);
    setStatus(
      "cancelStatus",
      `✅ Preview ready — ${(data?.total_items ?? 0)} open listing/offer row(s).`,
      true
    );
  } catch (err) {
    if (out) out.textContent = "";
    setStatus(
      "cancelStatus",
      "❌ " +
        (err.message || "Failed") +
        " — run supabase/sql/patches/admin_cancel_open_transfers.sql.",
      false
    );
  }
}

async function executeCancelOpenTransfers() {
  const params = cancelOpenParams();
  setStatus("cancelStatus", "Previewing before cancel…");
  let preview;
  try {
    const { data, error } = await supabase.rpc(
      "admin_cancel_open_transfers_preview",
      params
    );
    if (error) throw error;
    preview = data;
  } catch (err) {
    setStatus(
      "cancelStatus",
      "❌ " +
        (err.message || "Failed") +
        " — run supabase/sql/patches/admin_cancel_open_transfers.sql.",
      false
    );
    return;
  }

  const out = document.getElementById("cancelPreviewOut");
  if (out) out.textContent = formatCancelPreview(preview);

  const total = preview?.total_items ?? 0;
  if (total <= 0) {
    setStatus("cancelStatus", "Nothing matching to cancel.", true);
    return;
  }

  const perpetual = preview?.perpetual_renew_listings ?? 0;
  const msg =
    `Cancel ${total} open listing/offer row(s)?\n\n` +
    formatCancelPreview(preview) +
    (perpetual
      ? `\n\n⚠ Includes ${perpetual} perpetual/underperformance listing(s).`
      : "") +
    "\n\nCompleted transfers are not affected.";

  if (!confirm(msg)) {
    setStatus("cancelStatus", "Cancelled.", true);
    return;
  }

  setStatus("cancelStatus", "Cancelling…");
  try {
    const { data, error } = await supabase.rpc("admin_cancel_open_transfers", {
      ...params,
      p_confirm: true,
    });
    if (error) throw error;
    const c = data?.cancelled || {};
    setStatus(
      "cancelStatus",
      `✅ Cancelled — market ${c.market_listings ?? 0} listings / ${c.market_bids ?? 0} bids; ` +
        `draft ${c.draft_listings ?? 0} / ${c.draft_bids ?? 0}; ` +
        `direct offers ${c.direct_offers ?? 0}; ` +
        `manager draft ${c.manager_draft_listings ?? 0} / ${c.manager_draft_bids ?? 0}.`,
      true
    );
    await previewCancelOpenTransfers();
  } catch (err) {
    setStatus(
      "cancelStatus",
      "❌ " +
        (err.message || "Failed") +
        " — run supabase/sql/patches/admin_cancel_open_transfers.sql.",
      false
    );
  }
}
function ukDraftFmt() {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function formatKindScheduleLine(label, startRaw, finishRaw) {
  const fmt = ukDraftFmt();
  if (!startRaw) return `${label}: —`;
  const start = new Date(startRaw);
  const finish = finishRaw ? new Date(finishRaw) : null;
  const expired = isDraftScheduleExpired(start);
  return (
    `${label}: ${fmt.format(start)} UK` +
    (finish ? ` → finish ${fmt.format(finish)} UK` : " · ⚠ no secret finish") +
    (expired ? " · ended" : "")
  );
}

async function loadSettings() {
  const { data } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (!data) return;

  document.getElementById("draftAuctionSelect").value = data.draft_auction_enabled
    ? "true"
    : "false";
  const mgrDraftSel = document.getElementById("managerDraftAuctionSelect");
  if (mgrDraftSel) {
    mgrDraftSel.value = data.manager_draft_auction_enabled ? "true" : "false";
  }
  const clubAuctionSel = document.getElementById("clubAuctionSelect");
  if (clubAuctionSel) {
    clubAuctionSel.value = data.club_auction_enabled ? "true" : "false";
  }

  const el = document.getElementById("draftStartTime");
  if (!el) return;
  el.textContent = [
    formatKindScheduleLine(
      "Player",
      data.draft_auction_start_time,
      data.draft_random_finish_time
    ),
    formatKindScheduleLine(
      "Manager",
      data.manager_draft_auction_start_time,
      data.manager_draft_random_finish_time
    ),
    formatKindScheduleLine(
      "Club",
      data.club_auction_start_time,
      data.club_auction_random_finish_time
    ),
  ].join("\n");
}

function pickTimesForKind(kindStart) {
  const expired =
    !kindStart || isDraftScheduleExpired(kindStart ? new Date(kindStart) : null);
  if (!expired && kindStart) return null; // keep existing
  if (isPastNominalDraftStartUk()) return computeLateDraftStartNow();
  return computeNextDraftTimesFromNow();
}

async function setKindSchedule(kind, times) {
  const { error } = await supabase.rpc("admin_set_draft_schedule", {
    p_kind: kind,
    p_start: times.draftStartISO,
    p_finish: times.randomFinishISO,
  });
  if (error) throw error;
}

async function saveSettings() {
  const draft_auction_enabled =
    document.getElementById("draftAuctionSelect").value === "true";
  const manager_draft_auction_enabled =
    document.getElementById("managerDraftAuctionSelect")?.value === "true";
  const club_auction_enabled =
    document.getElementById("clubAuctionSelect")?.value === "true";

  const { data: current } = await supabase
    .from("global_settings")
    .select(
      "transfer_window_open, draft_auction_enabled, manager_draft_auction_enabled, club_auction_enabled, draft_auction_start_time, draft_random_finish_time, manager_draft_auction_start_time, manager_draft_random_finish_time, club_auction_start_time, club_auction_random_finish_time"
    )
    .eq("id", 1)
    .single();

  const transfer_window_open = current?.transfer_window_open === true;

  const turningOn = [];
  if (draft_auction_enabled && !current?.draft_auction_enabled) turningOn.push("player");
  if (manager_draft_auction_enabled && !current?.manager_draft_auction_enabled) {
    turningOn.push("manager");
  }
  if (club_auction_enabled && !current?.club_auction_enabled) turningOn.push("club");

  const needLateConfirm =
    isPastNominalDraftStartUk() &&
    turningOn.some((kind) => {
      const start =
        kind === "player"
          ? current?.draft_auction_start_time
          : kind === "manager"
            ? current?.manager_draft_auction_start_time
            : current?.club_auction_start_time;
      return !start || isDraftScheduleExpired(new Date(start));
    });

  if (needLateConfirm) {
    if (
      !confirm(
        "It is after 19:00 UK.\n\n" +
          `Turning on: ${turningOn.join(", ") || "draft type(s)"}.\n` +
          "Use LATE START for any type that needs a new clock?\n" +
          "• Day-1 = tonight 19:00 UK (bidding live now)\n" +
          "• Day-2 finish = tomorrow 18:50–18:59 UK\n" +
          "Other types keep their own clocks.\n\n" +
          "OK = continue · Cancel = abort."
      )
    ) {
      return;
    }
  }

  // Player flag + player schedule via edge (player columns only)
  let playerTimes = null;
  if (draft_auction_enabled) {
    playerTimes = pickTimesForKind(current?.draft_auction_start_time);
  }

  const { error } = await supabase.functions.invoke("update-global-settings", {
    body: {
      transfer_window_open,
      draft_auction_enabled,
      ...(playerTimes
        ? {
            draft_auction_start_time: playerTimes.draftStartISO,
            draft_random_finish_time: playerTimes.randomFinishISO,
          }
        : draft_auction_enabled
          ? {}
          : {
              draft_auction_start_time: null,
              draft_random_finish_time: null,
            }),
    },
  });

  if (error) {
    setStatus("settingsMessage", "❌ " + (error.message || "Error"), false);
    return;
  }

  try {
    const { error: mgrErr } = await supabase.rpc("admin_set_manager_draft_enabled", {
      p_enabled: manager_draft_auction_enabled,
    });
    if (mgrErr) throw mgrErr;

    const { error: clubErr } = await supabase.rpc("admin_set_club_auction_enabled", {
      p_enabled: club_auction_enabled,
    });
    if (clubErr) throw clubErr;

    if (playerTimes) {
      await setKindSchedule("player", playerTimes);
    }

    if (manager_draft_auction_enabled) {
      const mgrTimes = pickTimesForKind(current?.manager_draft_auction_start_time);
      if (mgrTimes) await setKindSchedule("manager", mgrTimes);
    } else {
      await supabase.rpc("admin_set_draft_schedule", {
        p_kind: "manager",
        p_start: null,
        p_finish: null,
      });
    }

    if (club_auction_enabled) {
      const clubTimes = pickTimesForKind(current?.club_auction_start_time);
      if (clubTimes) await setKindSchedule("club", clubTimes);
    } else {
      await supabase.rpc("admin_set_draft_schedule", {
        p_kind: "club",
        p_start: null,
        p_finish: null,
      });
    }

    setStatus("settingsMessage", "✅ Settings updated (independent clocks).", true);
  } catch (err) {
    setStatus(
      "settingsMessage",
      "❌ " +
        (err.message || "Failed") +
        " — run patches/draft_schedules_per_type.sql",
      false
    );
  }

  await loadGlobalSettings();
  await loadSettings();
}

async function seedClubAuctionListings() {
  setStatus("clubAuctionStatus", "Seeding listings…");
  try {
    const { data, error } = await supabase.rpc("admin_club_auction_seed_listings");
    if (error) throw error;
    setStatus(
      "clubAuctionStatus",
      `✅ Seeded ${data?.inserted ?? 0} clubs (${data?.skipped_existing_active ?? 0} already active).`,
      true
    );
  } catch (err) {
    setStatus(
      "clubAuctionStatus",
      "❌ " + (err.message || "Failed") + " — run patches/club_auction.sql.",
      false
    );
  }
}

async function settleClubAuctionsNow() {
  setStatus("clubAuctionStatus", "Settling club auctions…");
  try {
    const { data, error } = await supabase.rpc("admin_settle_club_auctions_now");
    if (error) throw error;
    const settled = data?.settled_count ?? 0;
    const left = data?.active_after ?? 0;
    const still = data?.still_active || [];
    let extra = "";
    if (still.length) {
      extra =
        " Still active: " +
        still.map((r) => `${r.club_short_name} (${r.leader_tag || "no bidder"})`).join("; ");
    }
    setStatus(
      "clubAuctionStatus",
      `✅ Club auctions settled: ${settled}. Still active: ${left}.${extra}`,
      left === 0
    );
  } catch (err) {
    setStatus(
      "clubAuctionStatus",
      "❌ " + (err.message || "Failed") + " — run patches/club_auction.sql.",
      false
    );
  }
}

async function lateStartDraftSchedule() {
  const kind = document.getElementById("lateStartKind")?.value || "manager";
  const label =
    kind === "player" ? "Player" : kind === "club" ? "Club" : "Manager";

  if (
    !confirm(
      `LATE START — ${label} draft only\n\n` +
        "• Day-1 = tonight 19:00 UK (bidding live now)\n" +
        "• Day-2 secret finish = tomorrow 18:50–18:59:58 UK\n" +
        "• Other auction types keep their own clocks\n\n" +
        "Continue?"
    )
  ) {
    return;
  }

  setStatus("settingsMessage", `Starting ${label} schedule now…`);
  try {
    const times = computeLateDraftStartNow();
    if (!times?.draftStartISO || !times?.randomFinishISO) {
      throw new Error("Could not compute schedule times");
    }

    if (kind === "manager") {
      const { error: mgrErr } = await supabase.rpc("admin_set_manager_draft_enabled", {
        p_enabled: true,
      });
      if (mgrErr) throw mgrErr;
    } else if (kind === "club") {
      const { error: clubErr } = await supabase.rpc("admin_set_club_auction_enabled", {
        p_enabled: true,
      });
      if (clubErr) throw clubErr;
    } else {
      const { error } = await supabase.functions.invoke("update-global-settings", {
        body: {
          draft_auction_enabled: true,
          draft_auction_start_time: times.draftStartISO,
          draft_random_finish_time: times.randomFinishISO,
        },
      });
      if (error) throw error;
    }

    await setKindSchedule(kind, times);

    const fmt = ukDraftFmt();
    setStatus(
      "settingsMessage",
      `✅ ${label} late start — open from ${fmt.format(new Date(times.draftStartISO))} UK · ` +
        `finish ${fmt.format(new Date(times.randomFinishISO))} UK.`,
      true
    );
    await loadGlobalSettings();
    await loadSettings();
  } catch (err) {
    setStatus(
      "settingsMessage",
      "❌ " +
        (err.message || "Failed") +
        " — run patches/draft_schedules_per_type.sql",
      false
    );
  }
}

async function resetDraftSchedule() {
  if (
    !confirm(
      "Reset draft schedule?\n\nClears start/finish times and turns player + manager + club auctions off. Completed transfers and bids are kept."
    )
  ) {
    return;
  }

  setStatus("resetDraftStatus", "Resetting…");
  const { error } = await supabase.rpc("admin_reset_draft_auction");

  if (error) {
    setStatus(
      "resetDraftStatus",
      "❌ " +
        (error.message || "Failed") +
        " — run admin_reset_draft_auction.sql in Supabase.",
      false
    );
    return;
  }

  setStatus("resetDraftStatus", "✅ Draft schedule reset.", true);
  await loadGlobalSettings();
  await loadSettings();
}

async function settleManagerDraftsNow() {
  setStatus("transferEngineStatus", "Settling manager drafts…");
  try {
    const { data, error } = await supabase.rpc("admin_settle_manager_drafts_now");
    if (error) throw error;
    const settled = data?.manager_draft_settled_count ?? 0;
    const left = data?.active_manager_draft_after ?? 0;
    const still = data?.still_active || [];
    let extra = "";
    if (still.length) {
      extra =
        " Still active: " +
        still
          .map(
            (r) =>
              `${r.manager_name || r.manager_id} (${r.high_bidder || "no bidder"})`
          )
          .join("; ");
    }
    setStatus(
      "transferEngineStatus",
      `✅ Manager drafts settled: ${settled}. Still active: ${left}.${extra}`,
      left === 0
    );
  } catch (err) {
    const msg = err.message || "Failed";
    setStatus(
      "transferEngineStatus",
      "❌ " +
        msg +
        (msg.includes("manager_assign_to_club")
          ? " — run supabase/sql/patches/manager_draft_auto_settle.sql in Supabase."
          : msg.includes("owner_inbox_send")
            ? " — run supabase/sql/patches/owner_inbox_send_dedupe.sql in Supabase."
            : " — run supabase/sql/patches/manager_draft_auto_settle.sql in Supabase."),
      false
    );
  }
}

async function forceSettlePlayerDrafts() {
  setStatus("transferEngineStatus", "Force-settling player drafts…");
  try {
    const { data, error } = await supabase.rpc("admin_force_settle_player_drafts", {
      p_batch_limit: 50,
    });
    if (error) throw error;
    const fails = Array.isArray(data?.failures) ? data.failures : [];
    const failNote = fails.length
      ? ` Failures: ${fails
          .slice(0, 5)
          .map((f) => `${f.player_id || f.listing_id}: ${f.error}`)
          .join(" · ")}`
      : "";
    const gate =
      data?.was_blocked_by_7pm_list
        ? " (normal engine was blocked by 7pm transfer-list)"
        : data?.secret_finish_passed === false
          ? " (secret finish not passed yet)"
          : "";
    setStatus(
      "transferEngineStatus",
      `✅ Force settle${gate}. Closed/settled: ${data?.closed_or_settled ?? "?"}. ` +
        `Active before: ${data?.active_before ?? "?"}, after: ${data?.active_after ?? "?"}.` +
        failNote,
      fails.length === 0 && Number(data?.active_after || 0) === 0
    );
  } catch (err) {
    const msg = err.message || "Failed";
    setStatus(
      "transferEngineStatus",
      "❌ " +
        msg +
        (/admin_force_settle_player_drafts|Could not find the function/i.test(msg)
          ? " — re-run supabase/sql/patches/draft_settlement_skip_season_excluded.sql in Supabase."
          : ""),
      false
    );
  }
}

async function runTransferEngine() {
  setStatus("transferEngineStatus", "Running…");
  try {
    const { data, error } = await supabase.rpc("admin_transferengine_run");
    if (error) throw error;
    if (data && data.ok === false) {
      throw new Error(data.error || data.note || "Transfer engine reported failure");
    }
    const mgrSettled = data?.manager_draft_settled_count ?? 0;
    const mgrLeft = data?.active_manager_draft_after ?? "?";
    const clubSettled = data?.club_auction_settled_count ?? 0;
    const clubLeft = data?.active_club_auction_after ?? "?";
    const excluded = data?.active_excluded_listings_before;
    const exclNote =
      excluded > 0
        ? ` Excluded listings present: ${excluded}.`
        : "";
    const gateNote = data?.blocked_by_7pm_transfer_list
      ? " ⚠ Player drafts waiting — blocked by same-evening 7pm transfer-list auctions. Use Force settle player drafts if you want them now."
      : data?.secret_finish_passed === false
        ? " ⚠ Secret draft finish has not passed yet."
        : "";
    setStatus(
      "transferEngineStatus",
      `✅ Ran at ${new Date(data?.ran_at || Date.now()).toLocaleString("en-GB")}. ` +
        `Stuck standard: ${data?.stuck_standard_before ?? "?"}. ` +
        `Player drafts settled: ${data?.draft_settled_count ?? "?"}, left: ${data?.active_draft_after ?? "?"}. ` +
        `Manager drafts settled: ${mgrSettled}, still active: ${mgrLeft}. ` +
        `Club auctions settled: ${clubSettled}, still active: ${clubLeft}.` +
        exclNote +
        gateNote,
      true
    );
  } catch (err) {
    const msg = err.message || "Failed";
    let hint = " — run admin_transferengine_run.sql in Supabase.";
    if (/excluded from GPSL|season exclusion/i.test(msg)) {
      hint =
        " — re-run the FULL file supabase/sql/patches/draft_settlement_skip_season_excluded.sql in Supabase SQL Editor (must succeed with no errors), then Run transfer engine again.";
    }
    setStatus("transferEngineStatus", "❌ " + msg + hint, false);
  }
}
