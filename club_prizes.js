import { initGlobal, supabase, getAuthUserFast } from "./global.js";

let inventory = [];

function setStatus(msg, kind = "") {
  const el = document.getElementById("prizeStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.className = "status" + (kind === "ok" ? " ok" : kind === "err" ? " err" : "");
}

function labelItem(it) {
  if (it.prize_type === "medical_token") return `Medical −${it.param_int} matches`;
  if (it.prize_type === "fee_discount") return `Fee discount ${it.param_int}%`;
  if (it.prize_type === "appeal_card") return "Red card appeal card";
  return it.prize_type;
}

function renderInventory() {
  const el = document.getElementById("prizeInventory");
  if (!inventory.length) {
    el.innerHTML = '<p class="meta">No prize items yet. Win a period bonus by completing all challenges in a window.</p>';
    return;
  }
  el.innerHTML = inventory
    .map((it) => {
      const ctx =
        it.status === "locked" && it.locked_context
          ? ` · locked to ${it.locked_context.kind} #${it.locked_context.id}`
          : it.status === "pending_review"
            ? " · appeal pending review"
            : "";
      return `<div class="prize-row">
        <div>
          <div class="prize-label">${labelItem(it)}</div>
          <div class="prize-meta">${it.status}${ctx}${it.source ? ` · ${it.source}` : ""}</div>
        </div>
      </div>`;
    })
    .join("");

  const discSel = document.getElementById("discountTokenSelect");
  const appealSel = document.getElementById("appealCardSelect");
  const discounts = inventory.filter((i) => i.prize_type === "fee_discount" && i.status === "available");
  const locked = inventory.filter((i) => i.prize_type === "fee_discount" && i.status === "locked");
  const appeals = inventory.filter((i) => i.prize_type === "appeal_card" && i.status === "available");

  discSel.innerHTML =
    (locked.length
      ? locked.map((i) => `<option value="${i.id}">${i.param_int}% (locked)</option>`).join("")
      : "") +
    (discounts.length
      ? discounts.map((i) => `<option value="${i.id}">${i.param_int}%</option>`).join("")
      : '<option value="">No available discounts</option>');

  appealSel.innerHTML = appeals.length
    ? appeals.map((i) => `<option value="${i.id}">Appeal card #${i.id}</option>`).join("")
    : '<option value="">No appeal cards</option>';
}

async function loadInventory() {
  const { data, error } = await supabase.rpc("club_prize_inventory_state");
  if (error) {
    setStatus("❌ " + error.message + " — run competition_challenge_prize_packs SQL", "err");
    return;
  }
  inventory = data?.items || [];
  renderInventory();
}

async function loadSuspensions() {
  const sel = document.getElementById("appealSuspensionSelect");
  const { data, error } = await supabase.rpc("club_appealable_red_suspensions");
  if (error) {
    sel.innerHTML = `<option value="">${error.message}</option>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    sel.innerHTML = '<option value="">No active red-card bans</option>';
    return;
  }
  sel.innerHTML = rows
    .map(
      (s) =>
        `<option value="${s.suspension_id}">${s.player_name || s.player_id} (${s.pending_matches} left)</option>`
    )
    .join("");
}

async function lockDiscount() {
  const id = Number(document.getElementById("discountTokenSelect").value);
  const kind = document.getElementById("discountContextKind").value;
  const ctxId = Number(document.getElementById("discountContextId").value);
  if (!id || !ctxId) {
    setStatus("Pick a token and enter a listing/auction ID.", "err");
    return;
  }
  setStatus("Locking…");
  const { error } = await supabase.rpc("prize_lock_fee_discount", {
    p_inventory_id: id,
    p_context_kind: kind,
    p_context_id: ctxId,
  });
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus("Discount locked.", "ok");
  await loadInventory();
}

async function unlockDiscount() {
  setStatus("Unlocking…");
  const { error } = await supabase.rpc("prize_unlock_fee_discount", {});
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus("Discount unlocked.", "ok");
  await loadInventory();
}

async function submitAppeal() {
  const inv = Number(document.getElementById("appealCardSelect").value);
  const sus = Number(document.getElementById("appealSuspensionSelect").value);
  const note = document.getElementById("appealNote").value;
  if (!inv || !sus) {
    setStatus("Select an appeal card and a suspension.", "err");
    return;
  }
  if (!confirm("Submit appeal? Card is held pending admin review (consumed if rejected).")) return;
  setStatus("Submitting…");
  const { error } = await supabase.rpc("prize_submit_suspension_appeal", {
    p_suspension_id: sus,
    p_inventory_id: inv,
    p_owner_note: note || null,
  });
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus("Appeal submitted for admin review.", "ok");
  await loadInventory();
  await loadSuspensions();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    window.location = "login.html";
    return;
  }
  document.getElementById("lockDiscountBtn").onclick = lockDiscount;
  document.getElementById("unlockDiscountBtn").onclick = unlockDiscount;
  document.getElementById("submitAppealBtn").onclick = submitAppeal;
  await loadInventory();
  await loadSuspensions();
});
