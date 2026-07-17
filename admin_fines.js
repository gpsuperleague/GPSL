import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  formatMoney,
  loadCurrentSeason,
  GPSL_MONTH_LABELS,
  GPSL_MONTH_ORDER,
  CUP_LABELS,
  DIVISION_LABELS,
} from "./competition.js";

primeAdminPageChrome();

let tariffs = [];
let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const season = await loadCurrentSeason(supabase);
  currentSeasonId = season?.id ?? null;

  fillMonthSelect();
  await loadClubs();
  await loadTariffs();
  await loadRecent();
  await loadFineFixtures();

  document.getElementById("fineTariffSelect").onchange = onTariffPick;
  document.getElementById("fineClubSelect").onchange = () => loadFineFixtures();
  document.getElementById("fineFixtureMonth").onchange = () => loadFineFixtures();
  document.getElementById("applyFineBtn").onclick = applyFine;
  document.getElementById("applyPointsBtn").onclick = applyPointsAdjustment;
  document.getElementById("seedFinesBtn").onclick = seedTariffs;
  document.getElementById("reloadFinesBtn").onclick = () => loadTariffs();
  document.getElementById("saveFineTariffBtn").onclick = saveTariff;
  document.getElementById("clearFineFormBtn").onclick = clearFineForm;
});

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fillMonthSelect() {
  const sel = document.getElementById("fineFixtureMonth");
  if (!sel) return;
  sel.innerHTML =
    `<option value="">All months</option>` +
    GPSL_MONTH_ORDER.map(
      (m) => `<option value="${m}">${GPSL_MONTH_LABELS[m] || m}</option>`
    ).join("");
}

function fixtureCompetitionLabel(f) {
  if (f.competition_type === "cup") {
    const cup = CUP_LABELS[f.cup_code] || f.cup_code || "Cup";
    const round = f.cup_round != null ? ` R${f.cup_round}` : "";
    return `${cup}${round}`;
  }
  if (f.competition_type === "playoff") return "Playoff";
  const div = DIVISION_LABELS[f.division] || f.division || "League";
  return f.matchday != null ? `${div} MD${f.matchday}` : div;
}

function fixtureOptionLabel(f) {
  const month = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month || "?";
  const ha = `${f.home_club_short_name} vs ${f.away_club_short_name}`;
  const score =
    f.status === "played" && f.home_goals != null && f.away_goals != null
      ? ` ${f.home_goals}–${f.away_goals}`
      : "";
  const status = f.status && f.status !== "scheduled" ? ` · ${f.status}` : "";
  return `#${f.id} · ${month} · ${fixtureCompetitionLabel(f)} · ${ha}${score}${status}`;
}

async function loadFineFixtures() {
  const sel = document.getElementById("fineFixtureId");
  if (!sel) return;

  const club = document.getElementById("fineClubSelect")?.value || "";
  const month = document.getElementById("fineFixtureMonth")?.value || "";
  const prev = sel.value;

  if (!club) {
    sel.innerHTML = `<option value="">— Select a club first —</option>`;
    return;
  }

  sel.innerHTML = `<option value="">Loading…</option>`;

  let query = supabase
    .from("competition_fixtures")
    .select(
      "id, competition_type, division, cup_code, cup_round, matchday, gpsl_month, week_in_month, home_club_short_name, away_club_short_name, status, home_goals, away_goals"
    )
    .or(`home_club_short_name.eq.${club},away_club_short_name.eq.${club}`)
    .order("matchday", { ascending: true })
    .limit(500);

  if (currentSeasonId) {
    query = query.eq("season_id", currentSeasonId);
  }
  if (month) {
    query = query.eq("gpsl_month", month);
  }

  const { data, error } = await query;

  if (error) {
    sel.innerHTML = `<option value="">— Could not load fixtures —</option>`;
    console.warn("loadFineFixtures:", error);
    return;
  }

  const monthSort = Object.fromEntries(GPSL_MONTH_ORDER.map((m, i) => [m, i]));
  const rows = (data || []).slice().sort((a, b) => {
    const ma = monthSort[a.gpsl_month] ?? 99;
    const mb = monthSort[b.gpsl_month] ?? 99;
    if (ma !== mb) return ma - mb;
    return (a.matchday || 0) - (b.matchday || 0) || a.id - b.id;
  });

  const none = `<option value="">— None (optional) —</option>`;
  if (!rows.length) {
    sel.innerHTML =
      none +
      `<option value="" disabled>${
        month ? "No fixtures for this club in that month" : "No fixtures for this club"
      }</option>`;
    return;
  }

  sel.innerHTML =
    none +
    rows
      .map(
        (f) =>
          `<option value="${f.id}">${escapeHtml(fixtureOptionLabel(f))}</option>`
      )
      .join("");

  if (prev && [...sel.options].some((o) => o.value === prev)) {
    sel.value = prev;
  }
}

async function loadClubs() {
  const { data } = await supabase.from("Clubs").select("ShortName, Club").order("Club");
  const options = (data || [])
    .map((c) => `<option value="${c.ShortName}">${c.Club || c.ShortName}</option>`)
    .join("");
  document.getElementById("fineClubSelect").innerHTML = options;
  const pointsSel = document.getElementById("pointsClubSelect");
  if (pointsSel) pointsSel.innerHTML = options;
}

async function applyPointsAdjustment() {
  const club = document.getElementById("pointsClubSelect").value;
  const delta = parseInt(document.getElementById("pointsDelta").value, 10);
  const reason = document.getElementById("pointsReason").value.trim();
  if (!club || !Number.isFinite(delta) || delta === 0) {
    setStatus("applyPointsStatus", "Enter club and non-zero points delta.", false);
    return;
  }
  if (!reason) {
    setStatus("applyPointsStatus", "Reason is required.", false);
    return;
  }
  if (!confirm(`${delta > 0 ? "Add" : "Deduct"} ${Math.abs(delta)} pts for ${club}?`)) return;

  setStatus("applyPointsStatus", "Applying…");
  const { error } = await supabase.rpc("competition_admin_adjust_league_points", {
    p_club_short_name: club,
    p_points_delta: delta,
    p_reason: reason,
    p_season_id: null,
  });
  setStatus("applyPointsStatus", error ? "❌ " + error.message : "✅ Points adjusted — owner notified.", !error);
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

  let inboxNote = "";
  if (data?.applied_id) {
    const { error: inboxErr } = await supabase.rpc("owner_inbox_notify_fine_applied", {
      p_applied_id: data.applied_id,
    });
    if (inboxErr) {
      inboxNote = " (inbox: run patches/owner_inbox_fine_fix.sql in Supabase)";
      console.warn("owner_inbox_notify_fine_applied:", inboxErr);
    } else {
      inboxNote = " Owner notified in inbox.";
    }
  }

  const dir = data?.direction === "compensation" ? "Credited" : "Fined";
  setStatus(
    "applyFineStatus",
    `✅ ${dir} ${club} ${formatMoney(data?.amount ?? 0)} (${code}).${inboxNote}`,
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
