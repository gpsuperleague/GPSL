import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

let tariffs = [];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadClubs();
  await loadTariffs();
  await loadRecent();

  document.getElementById("fineTariffSelect").onchange = onTariffPick;
  document.getElementById("applyFineBtn").onclick = applyFine;
  document.getElementById("seedFinesBtn").onclick = seedTariffs;
  document.getElementById("reloadFinesBtn").onclick = () => loadTariffs();
  document.getElementById("saveFineTariffBtn").onclick = saveTariff;
  document.getElementById("clearFineFormBtn").onclick = clearFineForm;
});

async function loadClubs() {
  const sel = document.getElementById("fineClubSelect");
  const { data } = await supabase.from("Clubs").select("ShortName, Club").order("Club");
  sel.innerHTML = (data || [])
    .map((c) => `<option value="${c.ShortName}">${c.Club || c.ShortName}</option>`)
    .join("");
}

function tariffOptionLabel(t) {
  const amt =
    t.amount_mode === "manual"
      ? "manual ₿"
      : formatMoney(Number(t.amount || 0));
  const dir = t.direction === "compensation" ? "credit" : "debit";
  return `${t.label} — ${amt} (${dir})`;
}

function onTariffPick() {
  const code = document.getElementById("fineTariffSelect").value;
  const t = tariffs.find((x) => x.code === code);
  const override = document.getElementById("fineAmountOverride");
  if (!t || !override) return;
  if (t.amount_mode === "manual") {
    override.placeholder = "Enter amount";
    override.value = "";
  } else {
    override.placeholder = `Default ${formatMoney(t.amount)}`;
    override.value = t.amount != null ? String(t.amount) : "";
  }
}

async function loadTariffs() {
  const { data, error } = await supabase
    .from("competition_fine_tariff")
    .select("*")
    .order("category")
    .order("sort_order");

  if (error) {
    setStatus(
      "fineTariffStatus",
      "❌ " + error.message + " — run competition_fines.sql",
      false
    );
    return;
  }

  tariffs = data || [];
  const pick = document.getElementById("fineTariffSelect");
  pick.innerHTML = tariffs
    .filter((t) => t.is_active)
    .map((t) => `<option value="${t.code}">${tariffOptionLabel(t)}</option>`)
    .join("");

  const list = document.getElementById("fineTariffList");
  if (!tariffs.length) {
    list.innerHTML = "<p class='note'>No tariffs — click Seed Excel tariffs.</p>";
    return;
  }

  list.innerHTML = tariffs
    .map((t) => {
      const amt =
        t.amount_mode === "manual" ? "manual" : formatMoney(Number(t.amount || 0));
      return `
        <div class="challenge-admin-item">
          <div>
            <b>${t.label}</b>
            <span class="challenge-admin-meta">${t.code} · ${t.category} · ${t.direction} · ${amt}${t.is_active ? "" : " · inactive"}</span>
          </div>
          <button type="button" class="button fine-edit-btn" data-code="${t.code}">Edit</button>
        </div>
      `;
    })
    .join("");

  list.querySelectorAll(".fine-edit-btn").forEach((btn) => {
    btn.onclick = () => {
      const t = tariffs.find((x) => x.code === btn.dataset.code);
      if (t) fillEditForm(t);
    };
  });

  onTariffPick();
  setStatus("fineTariffStatus", `${tariffs.length} tariff(s) loaded.`, true);
}

function fillEditForm(t) {
  document.getElementById("fineEditCode").value = t.code;
  document.getElementById("fineEditCodeInput").value = t.code;
  document.getElementById("fineEditCodeInput").disabled = true;
  document.getElementById("fineEditLabel").value = t.label;
  document.getElementById("fineEditCategory").value = t.category;
  document.getElementById("fineEditDirection").value = t.direction;
  document.getElementById("fineEditAmount").value = t.amount != null ? String(t.amount) : "";
  document.getElementById("fineEditMode").value = t.amount_mode;
}

function clearFineForm() {
  document.getElementById("fineEditCode").value = "";
  document.getElementById("fineEditCodeInput").value = "";
  document.getElementById("fineEditCodeInput").disabled = false;
  document.getElementById("fineEditLabel").value = "";
  document.getElementById("fineEditAmount").value = "";
  setStatus("fineFormStatus", "");
}

async function saveTariff() {
  const code = document.getElementById("fineEditCodeInput").value.trim();
  const label = document.getElementById("fineEditLabel").value.trim();
  if (!code || !label) {
    setStatus("fineFormStatus", "Code and label required.", false);
    return;
  }

  const amountVal = document.getElementById("fineEditAmount").value;
  setStatus("fineFormStatus", "Saving…");
  const { error } = await supabase.rpc("competition_admin_save_fine_tariff", {
    p_tariff: {
      code,
      label,
      category: document.getElementById("fineEditCategory").value,
      direction: document.getElementById("fineEditDirection").value,
      amount: amountVal === "" ? null : Number(amountVal),
      amount_mode: document.getElementById("fineEditMode").value,
      is_active: true,
      sort_order: 0,
    },
  });

  if (error) {
    setStatus("fineFormStatus", "❌ " + error.message, false);
    return;
  }

  await loadTariffs();
  setStatus("fineFormStatus", "✅ Tariff saved.", true);
}

async function seedTariffs() {
  setStatus("fineTariffStatus", "Seeding…");
  const { data, error } = await supabase.rpc("competition_admin_seed_fine_tariffs");
  if (error) {
    setStatus("fineTariffStatus", "❌ " + error.message, false);
    return;
  }
  await loadTariffs();
  setStatus("fineTariffStatus", `✅ Seeded/updated ${data ?? 0} tariffs.`, true);
}

async function applyFine() {
  const club = document.getElementById("fineClubSelect").value;
  const code = document.getElementById("fineTariffSelect").value;
  const note = document.getElementById("fineNote").value.trim() || null;
  const fixtureRaw = document.getElementById("fineFixtureId").value;
  const fixtureId = fixtureRaw ? Number(fixtureRaw) : null;
  const overrideRaw = document.getElementById("fineAmountOverride").value;
  const amountOverride = overrideRaw ? Number(overrideRaw) : null;

  setStatus("applyFineStatus", "Applying…");
  const { data, error } = await supabase.rpc("competition_admin_apply_fine", {
    p_club_short_name: club,
    p_tariff_code: code,
    p_amount_override: amountOverride,
    p_note: note,
    p_fixture_id: fixtureId,
  });

  if (error) {
    setStatus("applyFineStatus", "❌ " + error.message, false);
    return;
  }

  const dir = data?.direction === "compensation" ? "Credited" : "Fined";
  setStatus(
    "applyFineStatus",
    `✅ ${dir} ${club} ${formatMoney(data?.amount ?? 0)} (${code}).`,
    true
  );
  await loadRecent();
}

async function loadRecent() {
  const list = document.getElementById("fineRecentList");
  const { data, error } = await supabase
    .from("competition_fine_applied")
    .select("*, tariff:competition_fine_tariff(label)")
    .order("applied_at", { ascending: false })
    .limit(25);

  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message}</p>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = "<p class='note'>No fines applied yet.</p>";
    return;
  }

  list.innerHTML = data
    .map((r) => {
      const sign = r.direction === "compensation" ? "+" : "−";
      const label = r.tariff?.label || r.tariff_code;
      return `<div class="challenge-admin-item">
        <span><b>${r.club_short_name}</b> ${sign}${formatMoney(r.amount)} — ${label}
        <span class="challenge-admin-meta">${new Date(r.applied_at).toLocaleString("en-GB")}</span></span>
      </div>`;
    })
    .join("");
}
