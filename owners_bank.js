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

/** Opening first, then oldest → newest (migrated bets can pre-date the opening row). */
function sortStatementEntries(entries) {
  return [...entries].sort((a, b) => {
    const aOpen = a.entry_type === "opening_balance" ? 0 : 1;
    const bOpen = b.entry_type === "opening_balance" ? 0 : 1;
    if (aOpen !== bOpen) return aOpen - bOpen;
    const ta = new Date(a.created_at).getTime() || 0;
    const tb = new Date(b.created_at).getTime() || 0;
    if (ta !== tb) return ta - tb;
    return (Number(a.id) || 0) - (Number(b.id) || 0);
  });
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

  const entries = sortStatementEntries(
    Array.isArray(data?.entries) ? data.entries : []
  );

  // Forward running balance: after each line (opening 50k, then 49k, then 48k…)
  let run = 0;
  const rows = entries.map((e) => {
    const amt = Number(e.amount) || 0;
    run = Math.round((run + amt) * 100) / 100;
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
      <td class="num ob-run">${formatMoney(run)}</td>
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

  const welcome = document.getElementById("obWelcome");
  try {
    const { data: self } = await supabase.rpc("owner_registry_get_self");
    const tag = String(self?.owner_tag || "").trim();
    if (welcome) {
      welcome.textContent = tag
        ? `${tag} Personal Account`
        : "Personal Account";
    }
    if (tag) document.title = `${tag} · GPSL Building Society`;
  } catch {
    if (welcome) welcome.textContent = "Personal Account";
  }

  document.getElementById("obRefresh")?.addEventListener("click", () => loadStatement());
  await loadStatement();
});
