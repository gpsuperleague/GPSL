import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

let catalogue = [];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function statusLocal(msg, ok = true) {
  const el = document.getElementById("oshStatus");
  if (el) {
    el.textContent = msg || "";
    el.style.color = ok ? "#9fdf9f" : "#e07070";
  }
  setStatus(msg, ok);
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("secSaveBtn").onclick = saveSection;
  document.getElementById("secClearBtn").onclick = clearSectionForm;
  document.getElementById("itemSaveBtn").onclick = saveItem;
  document.getElementById("itemClearBtn").onclick = clearItemForm;
  document.getElementById("oshAdjBtn").onclick = adjustWallet;
  document.getElementById("oshBackfillBtn").onclick = backfillOpenings;
  document.getElementById("itemPrize").onchange = onPrizeTypeChange;

  await reloadCatalogue();
});

function onPrizeTypeChange() {
  const p = document.getElementById("itemPrize")?.value;
  const param = document.getElementById("itemParam");
  if (!param) return;
  if (p === "appeal_card") {
    param.value = "";
    param.disabled = true;
  } else {
    param.disabled = false;
  }
}

async function reloadCatalogue() {
  const { data, error } = await supabase.rpc("owners_shop_catalogue", {
    p_include_inactive: true,
  });
  if (error) {
    statusLocal(error.message || "Failed to load catalogue", false);
    catalogue = [];
  } else {
    catalogue = Array.isArray(data) ? data : [];
    statusLocal(`Loaded ${catalogue.length} section(s).`);
  }
  renderSections();
  renderItems();
  fillSectionSelect();
}

function fillSectionSelect() {
  const sel = document.getElementById("itemSection");
  if (!sel) return;
  const prev = sel.value;
  sel.innerHTML = catalogue
    .map(
      (s) =>
        `<option value="${s.id}">${escapeHtml(s.label)} (${escapeHtml(s.code)})</option>`
    )
    .join("");
  if (prev) sel.value = prev;
}

function renderSections() {
  const tb = document.querySelector("#secTable tbody");
  if (!tb) return;
  tb.innerHTML = catalogue
    .map((s) => {
      const inactive = s.is_active ? "" : " osh-inactive";
      return `<tr class="${inactive}">
        <td><code>${escapeHtml(s.code)}</code></td>
        <td>${escapeHtml(s.label)}</td>
        <td>${escapeHtml(s.theme_key)}</td>
        <td>${s.sort_order}</td>
        <td>${s.is_active ? "Yes" : "No"}</td>
        <td><button type="button" class="button" data-edit-sec="${s.id}">Edit</button></td>
      </tr>`;
    })
    .join("");
  tb.querySelectorAll("[data-edit-sec]").forEach((btn) => {
    btn.onclick = () => editSection(Number(btn.getAttribute("data-edit-sec")));
  });
}

function renderItems() {
  const tb = document.querySelector("#itemTable tbody");
  if (!tb) return;
  const rows = [];
  for (const s of catalogue) {
    for (const i of s.items || []) {
      const inactive = i.is_active ? "" : " osh-inactive";
      const delivery =
        i.prize_type === "medical_token"
          ? `medical −${i.param_int}`
          : i.prize_type === "appeal_card"
            ? `appeal ×${i.quantity_granted}`
            : `${i.prize_type}${i.param_int != null ? ` ${i.param_int}` : ""} ×${i.quantity_granted}`;
      rows.push(`<tr class="${inactive}">
        <td><code>${escapeHtml(i.sku_code)}</code></td>
        <td>${escapeHtml(i.title)}${i.is_featured ? ' <span class="osh-meta">featured</span>' : ""}</td>
        <td>${escapeHtml(s.label)}</td>
        <td>${formatMoney(i.price)}</td>
        <td>${escapeHtml(delivery)}</td>
        <td>${i.is_active ? "Yes" : "No"}</td>
        <td><button type="button" class="button" data-edit-item="${i.id}" data-sec="${s.id}">Edit</button></td>
      </tr>`);
    }
  }
  tb.innerHTML = rows.join("") || `<tr><td colspan="7">No items yet.</td></tr>`;
  tb.querySelectorAll("[data-edit-item]").forEach((btn) => {
    btn.onclick = () =>
      editItem(Number(btn.getAttribute("data-edit-item")), Number(btn.getAttribute("data-sec")));
  });
}

function editSection(id) {
  const s = catalogue.find((x) => x.id === id);
  if (!s) return;
  document.getElementById("secId").value = s.id;
  document.getElementById("secCode").value = s.code || "";
  document.getElementById("secLabel").value = s.label || "";
  document.getElementById("secKicker").value = s.kicker || "";
  document.getElementById("secIntro").value = s.intro || "";
  document.getElementById("secTheme").value = s.theme_key || "default";
  document.getElementById("secSort").value = s.sort_order ?? 100;
  document.getElementById("secActive").value = s.is_active ? "true" : "false";
}

function clearSectionForm() {
  document.getElementById("secId").value = "";
  document.getElementById("secCode").value = "";
  document.getElementById("secLabel").value = "";
  document.getElementById("secKicker").value = "";
  document.getElementById("secIntro").value = "";
  document.getElementById("secTheme").value = "medical";
  document.getElementById("secSort").value = "100";
  document.getElementById("secActive").value = "true";
}

async function saveSection() {
  const idRaw = document.getElementById("secId").value;
  const payload = {
    p_id: idRaw ? Number(idRaw) : null,
    p_code: document.getElementById("secCode").value,
    p_label: document.getElementById("secLabel").value,
    p_kicker: document.getElementById("secKicker").value,
    p_intro: document.getElementById("secIntro").value,
    p_theme_key: document.getElementById("secTheme").value,
    p_sort_order: Number(document.getElementById("secSort").value) || 100,
    p_is_active: document.getElementById("secActive").value === "true",
  };
  const { data, error } = await supabase.rpc("admin_owners_shop_save_section", payload);
  if (error) {
    statusLocal(error.message || "Save section failed", false);
    return;
  }
  statusLocal(`Section saved (#${data?.id ?? "?"}).`);
  clearSectionForm();
  await reloadCatalogue();
}

function editItem(itemId, sectionId) {
  const s = catalogue.find((x) => x.id === sectionId);
  const i = s?.items?.find((x) => x.id === itemId);
  if (!i) return;
  document.getElementById("itemId").value = i.id;
  document.getElementById("itemSection").value = String(sectionId);
  document.getElementById("itemSku").value = i.sku_code || "";
  document.getElementById("itemTitle").value = i.title || "";
  document.getElementById("itemDesc").value = i.description || "";
  document.getElementById("itemPrice").value = i.price ?? 0;
  document.getElementById("itemPrize").value = i.prize_type || "medical_token";
  document.getElementById("itemParam").value = i.param_int ?? "";
  document.getElementById("itemQty").value = i.quantity_granted ?? 1;
  document.getElementById("itemBadge").value = i.badge_label || "";
  document.getElementById("itemSort").value = i.sort_order ?? 100;
  document.getElementById("itemActive").value = i.is_active ? "true" : "false";
  document.getElementById("itemFeatured").value = i.is_featured ? "true" : "false";
  onPrizeTypeChange();
}

function clearItemForm() {
  document.getElementById("itemId").value = "";
  document.getElementById("itemSku").value = "";
  document.getElementById("itemTitle").value = "";
  document.getElementById("itemDesc").value = "";
  document.getElementById("itemPrice").value = "500";
  document.getElementById("itemPrize").value = "medical_token";
  document.getElementById("itemParam").value = "4";
  document.getElementById("itemQty").value = "1";
  document.getElementById("itemBadge").value = "";
  document.getElementById("itemSort").value = "100";
  document.getElementById("itemActive").value = "true";
  document.getElementById("itemFeatured").value = "false";
  onPrizeTypeChange();
}

async function saveItem() {
  const idRaw = document.getElementById("itemId").value;
  const prize = document.getElementById("itemPrize").value;
  const paramRaw = document.getElementById("itemParam").value;
  const payload = {
    p_id: idRaw ? Number(idRaw) : null,
    p_section_id: Number(document.getElementById("itemSection").value) || null,
    p_sku_code: document.getElementById("itemSku").value,
    p_title: document.getElementById("itemTitle").value,
    p_description: document.getElementById("itemDesc").value,
    p_price: Number(document.getElementById("itemPrice").value),
    p_prize_type: prize,
    p_param_int: prize === "appeal_card" || paramRaw === "" ? null : Number(paramRaw),
    p_quantity_granted: Number(document.getElementById("itemQty").value) || 1,
    p_badge_label: document.getElementById("itemBadge").value,
    p_sort_order: Number(document.getElementById("itemSort").value) || 100,
    p_is_active: document.getElementById("itemActive").value === "true",
    p_is_featured: document.getElementById("itemFeatured").value === "true",
  };
  const { data, error } = await supabase.rpc("admin_owners_shop_save_item", payload);
  if (error) {
    statusLocal(error.message || "Save item failed", false);
    return;
  }
  statusLocal(`Item saved (#${data?.id ?? "?"}).`);
  clearItemForm();
  await reloadCatalogue();
}

async function adjustWallet() {
  const ownerId = document.getElementById("oshOwnerId").value.trim();
  const amount = Number(document.getElementById("oshAdjAmount").value);
  const note = document.getElementById("oshAdjNote").value.trim();
  if (!ownerId) {
    statusLocal("Owner UUID required", false);
    return;
  }
  const { data, error } = await supabase.rpc("admin_owner_wallet_adjust", {
    p_owner_id: ownerId,
    p_amount: amount,
    p_description: note || null,
  });
  if (error) {
    statusLocal(error.message || "Adjust failed", false);
    return;
  }
  statusLocal(`Wallet updated — balance ${formatMoney(data?.balance ?? 0)}.`);
}

async function backfillOpenings() {
  if (!confirm("Grant ₿50,000 opening balance to registry owners with empty wallets?")) return;
  const { data, error } = await supabase.rpc("admin_owner_wallet_backfill_opening");
  if (error) {
    statusLocal(error.message || "Backfill failed", false);
    return;
  }
  statusLocal(`Opening backfill done (approx ${data?.granted_approx ?? 0} new grants).`);
}
