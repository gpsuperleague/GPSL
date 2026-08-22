import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";

const TYPE_LABELS = {
  opening_balance: "Opening balance",
  bookies_expenditure: "Bookies stake",
  bookies_income: "Bookies win",
  shop_purchase: "Owners Shop",
  gpfl_prize: "GPFL prize",
  admin_credit: "Admin credit",
  admin_debit: "Admin debit",
};

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function setStatus(msg, ok = true) {
  const el = document.getElementById("obStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.style.color = ok ? "#ffcc66" : "#e07070";
}

function formatWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function typeLabel(t) {
  return TYPE_LABELS[t] || String(t || "Entry").replace(/_/g, " ");
}

async function loadStatement() {
  const { data, error } = await supabase.rpc("owner_wallet_statement_self", {
    p_limit: 200,
  });
  if (error) {
    setStatus(
      error.message.includes("owner_wallet")
        ? "Run owner_wallet_opening_50k_20260822.sql (after the shop wallet patch)."
        : error.message,
      false
    );
    document.getElementById("obBalance").textContent = "—";
    document.querySelector("#obStatement tbody").innerHTML =
      `<tr><td colspan="5" class="ob-empty">Could not load statement.</td></tr>`;
    return;
  }

  const balance = Number(data?.balance ?? 0);
  document.getElementById("obBalance").textContent = formatMoney(balance);

  const entries = Array.isArray(data?.entries) ? data.entries : [];
  // Entries arrive newest-first; compute running balance from current balance backwards
  let run = balance;
  const rows = entries.map((e) => {
    const amt = Number(e.amount) || 0;
    const balAfter = run;
    run = run - amt; // undo this entry to get prior balance
    const out = amt < 0 ? formatMoney(Math.abs(amt)) : "—";
    const inn = amt > 0 ? formatMoney(amt) : "—";
    const desc = e.description || typeLabel(e.entry_type);
    return `<tr>
      <td>${escapeHtml(formatWhen(e.created_at))}</td>
      <td>
        ${escapeHtml(desc)}
        <div class="ob-type">${escapeHtml(typeLabel(e.entry_type))}</div>
      </td>
      <td class="num ob-out">${out}</td>
      <td class="num ob-in">${inn}</td>
      <td class="num ob-run">${formatMoney(balAfter)}</td>
    </tr>`;
  });

  document.querySelector("#obStatement tbody").innerHTML =
    rows.join("") ||
    `<tr><td colspan="5" class="ob-empty">No movements yet — opening balance posts when your account is created.</td></tr>`;

  setStatus(`${entries.length} statement line(s).`);
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  document.getElementById("obRefresh")?.addEventListener("click", () => loadStatement());
  await loadStatement();
});
