import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const COUNT_LABELS = {
  clubs_with_owner: "Clubs with owner",
  contracted_players: "Contracted players",
  contracted_managers: "Contracted managers",
  club_finances_nonzero: "Non-zero club balances",
  finance_ledger_rows: "Finance ledger rows",
  bank_ledger_rows: "Bank ledger rows",
  player_transfer_bids: "Player transfer bids",
  player_transfer_listings: "Player listings",
  manager_transfer_bids: "Manager transfer bids",
  manager_transfer_listings: "Manager listings",
  transfer_history_rows: "Transfer history",
  club_auction_active: "Active club auctions",
  club_auction_bids: "Club auction bids",
  special_auctions: "Special auctions",
  club_loans: "Club loans",
  competition_seasons: "Competition seasons",
  competition_fixtures: "Fixtures",
  competition_inbox: "Inbox messages",
  international_nations_active: "International nations",
  owners_registry_active: "Owners (active)",
  owners_registry_awaiting_auction: "Owners (awaiting auction)",
  players_foreign_contract: "Foreign contract locks",
};

function parseStartingBalance(raw) {
  const s = String(raw ?? "").trim().replace(/,/g, "");
  if (!s) return null;
  const mMatch = /^(\d+(?:\.\d+)?)\s*m$/i.exec(s);
  if (mMatch) return Math.round(Number(mMatch[1]) * 1_000_000);
  const v = Number(s);
  if (!Number.isFinite(v) || v <= 0) return null;
  return Math.round(v);
}

function formatMoneyInput(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "";
  return String(Math.round(v));
}

function renderPreviewGrid(counts) {
  const grid = document.getElementById("previewGrid");
  if (!grid || !counts) return;
  grid.innerHTML = Object.entries(COUNT_LABELS)
    .map(([key, label]) => {
      const val = counts[key] ?? 0;
      return `<div>${label}: <span>${val}</span></div>`;
    })
    .join("");
  grid.hidden = false;
}

function updateArmBadge(enabled) {
  const badge = document.getElementById("armBadge");
  if (!badge) return;
  badge.textContent = enabled ? "ARMED" : "DISABLED";
  badge.className = enabled ? "arm-badge arm-on" : "arm-badge arm-off";
}

async function loadConfig() {
  const { data, error } = await supabase.rpc("admin_test_reset_get_config");
  if (error) {
    setStatus("armStatus", "Run admin_prelaunch_test_reset.sql — " + error.message, false);
    return;
  }
  updateArmBadge(!!data?.allow_test_environment_reset);
  const hint = document.getElementById("phraseHint");
  if (hint && data?.confirm_phrase) hint.textContent = data.confirm_phrase;
  const balInput = document.getElementById("startingBalance");
  if (balInput && data?.default_starting_balance > 0) {
    balInput.value = formatMoneyInput(data.default_starting_balance);
  }
}

async function setEnabled(enabled) {
  const msg = enabled
    ? "Enable test reset? Only use for pre-launch sandbox testing."
    : "Disable test reset? Execute will be blocked until re-enabled.";
  if (!confirm(msg)) return;

  setStatus("armStatus", "Updating…");
  const { data, error } = await supabase.rpc("admin_test_reset_set_enabled", {
    p_enabled: enabled,
  });
  if (error) {
    setStatus("armStatus", error.message, false);
    return;
  }
  updateArmBadge(!!data?.allow_test_environment_reset);
  setStatus(
    "armStatus",
    data?.allow_test_environment_reset ? "Test reset ARMED." : "Test reset disabled.",
    !data?.allow_test_environment_reset
  );
}

async function runPreview() {
  setStatus("previewStatus", "Loading preview…");
  const { data, error } = await supabase.rpc("admin_test_reset_preview");
  if (error) {
    setStatus("previewStatus", error.message, false);
    return;
  }
  renderPreviewGrid(data?.counts);
  setStatus(
    "previewStatus",
    `Preview at ${new Date(data?.preview_at || Date.now()).toLocaleString("en-GB")}. ` +
      (data?.allow_test_environment_reset ? "Reset is armed." : "Reset is NOT armed."),
    true
  );
}

async function runExecute() {
  const phrase = document.getElementById("confirmInput")?.value?.trim() || "";
  if (
    !confirm(
      "FINAL WARNING\n\nThis wipes owners, squads, finances, transfers, fixtures, and history.\n\nContinue?"
    )
  ) {
    return;
  }

  setStatus("executeStatus", "Running reset…");
  const startingBalance = parseStartingBalance(
    document.getElementById("startingBalance")?.value
  );
  if (!startingBalance) {
    setStatus(
      "executeStatus",
      "Invalid starting balance — use 550000000 or 550m",
      false
    );
    return;
  }
  const options = {
    starting_balance: startingBalance,
    reset_owners_to_auction: !!document.getElementById("optResetOwners")?.checked,
    clear_competition_history: !!document.getElementById("optClearHistory")?.checked,
    seed_club_auction: !!document.getElementById("optSeedClub")?.checked,
  };

  const { data, error } = await supabase.rpc("admin_test_reset_execute", {
    p_confirm_phrase: phrase,
    p_options: options,
  });

  if (error) {
    setStatus("executeStatus", error.message, false);
    return;
  }

  renderPreviewGrid(data?.result?.counts_after);
  const auditId = data?.audit_id;
  setStatus(
    "executeStatus",
    `Reset complete (audit #${auditId}). Re-register owners / enable club auction when ready.`,
    true
  );
  await loadConfig();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadConfig();

  document.getElementById("enableResetBtn")?.addEventListener("click", () => setEnabled(true));
  document.getElementById("disableResetBtn")?.addEventListener("click", () => setEnabled(false));
  document.getElementById("previewBtn")?.addEventListener("click", runPreview);
  document.getElementById("executeBtn")?.addEventListener("click", runExecute);
});
