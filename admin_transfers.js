import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  loadGlobalSettings,
  computeNextDraftTimesFromNow,
  isDraftScheduleExpired,
} from "./global.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadSettings();
  document.getElementById("saveSettingsBtn").onclick = saveSettings;
  document.getElementById("resetDraftBtn").onclick = resetDraftSchedule;
  document.getElementById("runTransferEngineBtn").onclick = runTransferEngine;
  document.getElementById("settleManagerDraftsBtn").onclick = settleManagerDraftsNow;
  document.getElementById("seedClubAuctionBtn").onclick = seedClubAuctionListings;
  document.getElementById("settleClubAuctionsBtn").onclick = settleClubAuctionsNow;
});

async function loadSettings() {
  const { data } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (!data) return;

  document.getElementById("transferWindowSelect").value = data.transfer_window_open
    ? "true"
    : "false";
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
  const anyDraft =
    data.draft_auction_enabled ||
    data.manager_draft_auction_enabled ||
    data.club_auction_enabled;
  if (anyDraft && data.draft_auction_start_time) {
    const ukFmt = new Intl.DateTimeFormat("en-GB", {
      timeZone: "Europe/London",
      weekday: "short",
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const start = new Date(data.draft_auction_start_time);
    const finish = data.draft_random_finish_time
      ? new Date(data.draft_random_finish_time)
      : null;
    const expired = isDraftScheduleExpired(start);
    el.textContent =
      `Draft start: ${ukFmt.format(start)} UK` +
      (finish ? ` · Secret finish: ${ukFmt.format(finish)} UK` : " · ⚠ No secret finish set") +
      (expired ? " · ⚠ Window ended — Save settings to schedule the next 7pm UK auction" : "");
  } else if (anyDraft) {
    el.textContent = "⚠ No draft start time — Save settings to schedule the next 7pm UK auction.";
  } else {
    el.textContent = "";
  }
}

async function saveSettings() {
  const transfer_window_open =
    document.getElementById("transferWindowSelect").value === "true";
  const draft_auction_enabled =
    document.getElementById("draftAuctionSelect").value === "true";
  const manager_draft_auction_enabled =
    document.getElementById("managerDraftAuctionSelect")?.value === "true";
  const club_auction_enabled =
    document.getElementById("clubAuctionSelect")?.value === "true";

  const { data: current } = await supabase
    .from("global_settings")
    .select(
      "draft_auction_enabled, manager_draft_auction_enabled, club_auction_enabled, draft_auction_start_time, draft_random_finish_time"
    )
    .eq("id", 1)
    .single();

  const wasAnyDraft =
    current?.draft_auction_enabled ||
    current?.manager_draft_auction_enabled ||
    current?.club_auction_enabled;
  const isAnyDraft =
    draft_auction_enabled || manager_draft_auction_enabled || club_auction_enabled;

  let draft_auction_start_time = current?.draft_auction_start_time || null;
  let draft_random_finish_time = current?.draft_random_finish_time || null;

  const scheduleExpired =
    isAnyDraft &&
    isDraftScheduleExpired(
      draft_auction_start_time ? new Date(draft_auction_start_time) : null
    );

  if (isAnyDraft && (!wasAnyDraft || scheduleExpired || !draft_auction_start_time)) {
    const times = computeNextDraftTimesFromNow();
    draft_auction_start_time = times.draftStartISO;
    draft_random_finish_time = times.randomFinishISO;
  } else if (!isAnyDraft) {
    draft_auction_start_time = null;
    draft_random_finish_time = null;
  }

  const { error } = await supabase.functions.invoke("update-global-settings", {
    body: {
      transfer_window_open,
      draft_auction_enabled,
      draft_random_finish_time,
      draft_auction_start_time,
    },
  });

  if (error) {
    setStatus("settingsMessage", "❌ " + (error.message || "Error"), false);
  } else {
    const { error: mgrErr } = await supabase.rpc("admin_set_manager_draft_enabled", {
      p_enabled: manager_draft_auction_enabled,
    });
    if (mgrErr) {
      setStatus(
        "settingsMessage",
        "❌ Manager draft flag: " +
          (mgrErr.message || "failed") +
          " — run managers_system.sql.",
        false
      );
    } else {
      const { error: clubErr } = await supabase.rpc("admin_set_club_auction_enabled", {
        p_enabled: club_auction_enabled,
      });
      if (clubErr) {
        setStatus(
          "settingsMessage",
          "❌ Club auction flag: " +
            (clubErr.message || "failed") +
            " — run patches/club_auction.sql.",
          false
        );
      } else if (isAnyDraft && draft_auction_start_time) {
        const { error: schedErr } = await supabase.rpc("admin_set_draft_auction_schedule", {
          p_start: draft_auction_start_time,
          p_finish: draft_random_finish_time,
        });
        if (schedErr) {
          setStatus(
            "settingsMessage",
            "✅ Flags saved. Schedule RPC missing — run managers_draft_schedule.sql, then save again.",
            true
          );
        } else {
          setStatus("settingsMessage", "✅ Settings updated.", true);
        }
      } else {
        setStatus("settingsMessage", "✅ Settings updated.", true);
      }
    }
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

async function resetDraftSchedule() {
  if (
    !confirm(
      "Reset draft schedule?\n\nClears start/finish times and turns the auction off. Completed transfers and bids are kept."
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

async function runTransferEngine() {
  setStatus("transferEngineStatus", "Running…");
  try {
    const { data, error } = await supabase.rpc("admin_transferengine_run");
    if (error) throw error;
    const mgrSettled = data?.manager_draft_settled_count ?? 0;
    const mgrLeft = data?.active_manager_draft_after ?? "?";
    const clubSettled = data?.club_auction_settled_count ?? 0;
    const clubLeft = data?.active_club_auction_after ?? "?";
    setStatus(
      "transferEngineStatus",
      `✅ Ran at ${new Date(data?.ran_at || Date.now()).toLocaleString("en-GB")}. ` +
        `Stuck standard: ${data?.stuck_standard_before ?? "?"}. ` +
        `Player drafts left: ${data?.active_draft_after ?? "?"}. ` +
        `Manager drafts settled: ${mgrSettled}, still active: ${mgrLeft}. ` +
        `Club auctions settled: ${clubSettled}, still active: ${clubLeft}.`,
      true
    );
  } catch (err) {
    setStatus(
      "transferEngineStatus",
      "❌ " +
        (err.message || "Failed") +
        " — run admin_transferengine_run.sql in Supabase.",
      false
    );
  }
}
