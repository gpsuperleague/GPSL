import { supabase } from "./supabase_client.js";

const params = new URLSearchParams(window.location.search);
const token = (params.get("token") || "").trim();
const decisionParam = (params.get("decision") || "").trim().toLowerCase();

const summaryEl = document.getElementById("summary");
const statusEl = document.getElementById("status");
const actionsEl = document.getElementById("actions");
const acceptBtn = document.getElementById("acceptBtn");
const declineBtn = document.getElementById("declineBtn");

function setStatus(msg, isError = false) {
  if (!statusEl) return;
  statusEl.textContent = msg || "";
  statusEl.style.color = isError ? "#f88" : "#fc6";
}

async function peek() {
  if (!token) {
    summaryEl.textContent = "Missing invite token. Open the link from your email.";
    return null;
  }
  const { data, error } = await supabase.rpc("season1_invite_peek_token", {
    p_token: token,
  });
  if (error) {
    summaryEl.textContent = "Could not load invite.";
    setStatus("❌ " + error.message, true);
    return null;
  }
  if (!data?.ok) {
    summaryEl.textContent = "This invite link is invalid or has expired.";
    return null;
  }
  const s1 = data.season1 || {};
  const tag = data.owner_tag || "Owner";
  if (s1.response) {
    summaryEl.textContent = `${tag} — already ${s1.response}. Queue #${s1.queue_num ?? "—"}.`;
    return data;
  }
  if (data.expired || s1.status === "expired") {
    summaryEl.textContent = `${tag} — this invite expired (${s1.deadline_label || "deadline passed"}).`;
    return data;
  }
  summaryEl.textContent = `${tag} — Season 1 invite #${s1.queue_num ?? "—"}. Deadline: ${
    s1.deadline_label || "48 hours from offer"
  }.`;
  if (s1.status === "offered" && !s1.response) {
    actionsEl.hidden = false;
  }
  return data;
}

async function respond(decision) {
  acceptBtn.disabled = true;
  declineBtn.disabled = true;
  setStatus(decision === "accept" ? "Accepting…" : "Declining…");
  const { data, error } = await supabase.rpc("owner_season1_invite_respond", {
    p_decision: decision,
    p_token: token,
  });
  if (error) {
    setStatus("❌ " + error.message, true);
    acceptBtn.disabled = false;
    declineBtn.disabled = false;
    return;
  }
  actionsEl.hidden = true;
  const response = data?.response || decision;
  summaryEl.textContent = data?.already
    ? `Already recorded as ${response}.`
    : `Thanks — recorded as ${response}.`;
  setStatus(response === "accepted" ? "✅ Accepted for Season 1." : "Declined.");
}

acceptBtn?.addEventListener("click", () => respond("accept"));
declineBtn?.addEventListener("click", () => respond("decline"));

const peekData = await peek();
if (
  peekData?.ok &&
  !peekData.season1?.response &&
  !peekData.expired &&
  (decisionParam === "accept" || decisionParam === "decline")
) {
  await respond(decisionParam);
}
