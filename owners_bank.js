import {
  supabase,
  initGlobal,
  isGpslAdminUser,
  getAuthUser,
} from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { formatMoney } from "./competition.js";

const SESSION_KEY = "gpsl_admin_building_society_owner";

const TYPE_LABELS = {
  opening_balance: "Opening balance",
  bookies_expenditure: "Bookies stake",
  bookies_income: "Bookies win",
  shop_purchase: "Owners Shop",
  agent_bribe: "Personal cheque",
  gpfl_prize: "GPFL prize",
  challenge_prize: "Challenge big prize",
  friendlies_prize: "Friendlies table prize",
  supporter_lottery_credit: "Supporters' lottery",
  admin_credit: "Admin credit",
  admin_debit: "Admin debit",
};

/** @type {string|null} admin preview of another owner's wallet */
let previewOwnerId = null;

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

function renderStatement(data) {
  const balance = Number(data?.balance ?? 0);
  document.getElementById("obBalance").textContent = formatMoney(balance);

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

  document.querySelector("#obStatement tbody").innerHTML =
    rows.join("") ||
    `<tr><td colspan="5" class="ob-empty">No movements yet — opening balance posts when your account is created.</td></tr>`;

  setStatus(`${entries.length} statement line(s).`);
}

async function loadStatement() {
  let data;
  let error;

  if (previewOwnerId) {
    ({ data, error } = await supabase.rpc("admin_owner_wallet_statement", {
      p_owner_id: previewOwnerId,
      p_limit: 200,
    }));
  } else {
    ({ data, error } = await supabase.rpc("owner_wallet_statement_self", {
      p_limit: 200,
    }));
  }

  if (error) {
    setStatus(
      error.message.includes("admin_owner_wallet")
        ? "Run admin_owner_wallets_overview_20261016.sql in Supabase."
        : error.message.includes("owner_wallet")
          ? "Run owner_wallet_opening_50k_20260822.sql (after the shop wallet patch)."
          : error.message,
      false
    );
    document.getElementById("obBalance").textContent = "—";
    document.querySelector("#obStatement tbody").innerHTML =
      `<tr><td colspan="5" class="ob-empty">Could not load statement.</td></tr>`;
    return;
  }

  renderStatement(data);

  const welcome = document.getElementById("obWelcome");
  if (previewOwnerId) {
    const tag = String(data?.owner_tag || "").trim();
    const club = String(data?.club_name || "").trim();
    if (welcome) {
      welcome.textContent = tag
        ? `Staff preview · ${tag}${club ? ` · ${club}` : ""}`
        : `Staff preview${club ? ` · ${club}` : ""}`;
    }
    if (tag) document.title = `${tag} · GPSL Building Society (preview)`;
  }
}

function ownerOptionLabel(r) {
  const tag = String(r.owner_tag || "").trim() || String(r.email || "Owner");
  const club = String(r.club_name || "").trim();
  const bal = formatMoney(Number(r.balance) || 0);
  return club ? `${tag} — ${club} (${bal})` : `${tag} (${bal})`;
}

/**
 * Admin-only dropdown on the Building Society page (same idea as club picker on Squad / Finances).
 */
async function mountAdminOwnerPicker(user) {
  if (!isGpslAdminUser(user)) return;

  const host = document.getElementById("staffOwnerPickerHost");
  if (!host) return;

  const { data, error } = await supabase.rpc("admin_owner_wallets_overview");
  if (error || !Array.isArray(data) || !data.length) {
    host.innerHTML = `<div class="staff-club-picker" style="margin:12px 20px 0;padding:10px 12px;background:#222;border:1px solid #444;border-radius:6px;font-size:13px;color:#e88;">
      Admin owner list unavailable — run <code>admin_owner_wallets_overview_20261016.sql</code>.
    </div>`;
    return;
  }

  const params = new URLSearchParams(window.location.search);
  const urlOwner = (params.get("owner") || "").trim() || null;
  const saved = (sessionStorage.getItem(SESSION_KEY) || "").trim() || null;
  const preferred = urlOwner || saved || null;

  const sorted = [...data].sort((a, b) => {
    const at = String(a.owner_tag || a.email || "").toLowerCase();
    const bt = String(b.owner_tag || b.email || "").toLowerCase();
    if (at < bt) return -1;
    if (at > bt) return 1;
    return 0;
  });

  host.replaceChildren();
  const wrap = document.createElement("div");
  wrap.className = "staff-club-picker";
  wrap.style.cssText =
    "margin:12px 20px 0;padding:10px 12px;background:#222;border:1px solid #444;border-radius:6px;font-size:13px;";

  const label = document.createElement("label");
  label.htmlFor = "staffOwnerSelect";
  label.textContent = "Preview owner: ";
  label.style.marginRight = "8px";

  const select = document.createElement("select");
  select.id = "staffOwnerSelect";
  select.style.cssText =
    "padding:6px 8px;background:#111;border:1px solid #555;color:#ddd;border-radius:4px;min-width:280px;max-width:100%;";

  const ownOpt = document.createElement("option");
  ownOpt.value = "__own__";
  ownOpt.textContent = "My account";
  select.appendChild(ownOpt);

  for (const r of sorted) {
    const opt = document.createElement("option");
    opt.value = r.owner_id;
    opt.textContent = ownerOptionLabel(r);
    select.appendChild(opt);
  }

  if (preferred && preferred !== user.id && [...select.options].some((o) => o.value === preferred)) {
    select.value = preferred;
    previewOwnerId = preferred;
  } else {
    select.value = "__own__";
    previewOwnerId = null;
  }

  const hint = document.createElement("div");
  hint.style.cssText = "margin-top:6px;color:#888;font-size:12px;line-height:1.35;";
  hint.textContent =
    "Admin only — pick any owner to see their Building Society statement as they see it.";

  wrap.appendChild(label);
  wrap.appendChild(select);
  wrap.appendChild(hint);
  host.appendChild(wrap);

  select.addEventListener("change", () => {
    const url = new URL(window.location.href);
    if (select.value === "__own__") {
      sessionStorage.removeItem(SESSION_KEY);
      url.searchParams.delete("owner");
      previewOwnerId = null;
    } else {
      sessionStorage.setItem(SESSION_KEY, select.value);
      url.searchParams.set("owner", select.value);
      previewOwnerId = select.value;
    }
    window.history.replaceState({}, "", url.toString());
    loadStatement();
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  await initGlobal();
  const user = await getAuthUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await mountAdminOwnerPicker(user);

  if (!previewOwnerId) {
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
  }

  document.getElementById("obRefresh")?.addEventListener("click", () => loadStatement());
  await loadStatement();
});
