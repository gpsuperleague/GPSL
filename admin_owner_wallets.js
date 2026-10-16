import { initAdminPage, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

const TYPE_LABELS = {
  opening_balance: "Opening balance",
  bookies_expenditure: "Bookies stake",
  bookies_income: "Bookies win",
  shop_purchase: "Owners Shop",
  gpfl_prize: "GPFL prize",
  challenge_prize: "Challenge big prize",
  friendlies_prize: "Friendlies table prize",
  supporter_lottery_credit: "Supporters' lottery",
  admin_credit: "Admin credit",
  admin_debit: "Admin debit",
};

/** @type {Array<Record<string, unknown>>} */
let ownerList = [];

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

/** Opening first, then oldest → newest (same as owners_bank.js). */
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

function ownerOptionLabel(r) {
  const tag = String(r.owner_tag || "").trim() || String(r.email || "Owner");
  const club = String(r.club_name || "").trim();
  const bal = formatMoney(Number(r.balance) || 0);
  return club ? `${tag} — ${club} (${bal})` : `${tag} (${bal})`;
}

function fillOwnerSelect(keepId) {
  const sel = document.getElementById("owOwnerSelect");
  if (!sel) return;
  const sorted = [...ownerList].sort((a, b) => {
    const at = String(a.owner_tag || a.email || "").toLowerCase();
    const bt = String(b.owner_tag || b.email || "").toLowerCase();
    if (at < bt) return -1;
    if (at > bt) return 1;
    return 0;
  });
  sel.innerHTML =
    `<option value="">— Select owner —</option>` +
    sorted
      .map(
        (r) =>
          `<option value="${escapeHtml(r.owner_id)}">${escapeHtml(ownerOptionLabel(r))}</option>`
      )
      .join("");
  if (keepId && sorted.some((r) => r.owner_id === keepId)) {
    sel.value = keepId;
  }
}

async function loadOwnerList() {
  const keep = document.getElementById("owOwnerSelect")?.value || "";
  setStatus("Loading owners…");
  const { data, error } = await supabase.rpc("admin_owner_wallets_overview");
  if (error) {
    setStatus(
      error.message.includes("admin_owner_wallets")
        ? "Run admin_owner_wallets_overview_20261016.sql in Supabase."
        : error.message,
      false
    );
    ownerList = [];
    fillOwnerSelect("");
    return;
  }
  ownerList = Array.isArray(data) ? data : [];
  fillOwnerSelect(keep);
  setStatus(`${ownerList.length} owners — pick one to preview their statement.`);
  if (keep) await loadStatement(keep);
}

async function loadStatement(ownerId) {
  const welcome = document.getElementById("obWelcome");
  const balEl = document.getElementById("obBalance");
  const tbody = document.querySelector("#obStatement tbody");
  if (!ownerId) {
    if (welcome) welcome.textContent = "Select an owner";
    if (balEl) balEl.textContent = "—";
    if (tbody) {
      tbody.innerHTML =
        `<tr><td colspan="5" class="ob-empty">Pick an owner above to load their statement.</td></tr>`;
    }
    setStatus("");
    return;
  }

  setStatus("Loading statement…");
  const { data, error } = await supabase.rpc("admin_owner_wallet_statement", {
    p_owner_id: ownerId,
    p_limit: 200,
  });
  if (error) {
    setStatus(error.message, false);
    if (balEl) balEl.textContent = "—";
    if (tbody) {
      tbody.innerHTML =
        `<tr><td colspan="5" class="ob-empty">Could not load statement.</td></tr>`;
    }
    return;
  }

  const tag = String(data?.owner_tag || "").trim();
  const club = String(data?.club_name || "").trim();
  if (welcome) {
    welcome.textContent = tag
      ? `${tag} Personal Account${club ? ` · ${club}` : ""}`
      : club
        ? `Personal Account · ${club}`
        : "Personal Account";
  }
  document.title = `${tag || "Owner"} · Building Society (admin)`;

  const balance = Number(data?.balance ?? 0);
  if (balEl) balEl.textContent = formatMoney(balance);

  const entries = sortStatementEntries(
    Array.isArray(data?.entries) ? data.entries : []
  );

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

  if (tbody) {
    tbody.innerHTML =
      rows.join("") ||
      `<tr><td colspan="5" class="ob-empty">No movements yet.</td></tr>`;
  }
  setStatus(`${entries.length} statement line(s) · balance ${formatMoney(balance)}.`);
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await initAdminPage(); // admin only
  if (!user) return;

  document.getElementById("owOwnerSelect")?.addEventListener("change", (e) => {
    loadStatement(e.target.value);
  });
  document.getElementById("owReloadList")?.addEventListener("click", () => loadOwnerList());
  document.getElementById("obRefresh")?.addEventListener("click", () => {
    const id = document.getElementById("owOwnerSelect")?.value;
    loadStatement(id);
  });

  await loadOwnerList();
});
