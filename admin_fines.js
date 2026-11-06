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
let videoReportCodes = new Set();
let videoReportColumn = false;
let tariffFilter = "all";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;

  const season = await loadCurrentSeason(supabase);
  currentSeasonId = season?.id ?? null;

  document.getElementById("autoFinesOffBtn").onclick = () => setAutoFines(false);
  document.getElementById("autoFinesOnBtn").onclick = () => setAutoFines(true);
  await loadAutoFines();

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
  document.getElementById("tariffFilterAll").onclick = () => setTariffFilter("all");
  document.getElementById("tariffFilterVideo").onclick = () => setTariffFilter("video");
  document.getElementById("tariffFilterOther").onclick = () => setTariffFilter("other");
});

function renderAutoFines(s) {
  const el = document.getElementById("autoFinesState");
  if (!el) return;
  if (!s) {
    el.innerHTML = "❌ Run <code>auto_fines_ease_in_switch_20260929.sql</code> in Supabase.";
    return;
  }
  const liveFrom = s.live_from ? new Date(s.live_from) : null;
  const state = s.active
    ? `<b style="color:#8d8;">ON</b> — automatic fines are being charged.`
    : `<b style="color:#fc6;">OFF (ease-in)</b> — fines are waived and owners get "would have been fined" messages.`;
  const schedule =
    !s.enabled && liveFrom
      ? `<br>Auto switch-on: <b>${liveFrom.toLocaleString("en-GB")}</b>`
      : "";
  const waived = Number(s.waived_count || 0)
    ? `<br>Waived so far: <b>${s.waived_count}</b> fines, ${formatMoney(s.waived_total || 0)} not charged.`
    : "";
  el.innerHTML = `${state}${schedule}${waived}`;
  const input = document.getElementById("autoFinesLiveFrom");
  if (input && liveFrom && !s.enabled) {
    const local = new Date(liveFrom.getTime() - liveFrom.getTimezoneOffset() * 60000);
    input.value = local.toISOString().slice(0, 16);
  }
  renderFineSwitches(s);
}

function renderFineSwitches(s) {
  const wrap = document.getElementById("autoFineSwitches");
  if (!wrap) return;
  const rows = Array.isArray(s?.switches) ? s.switches : null;
  if (!rows) {
    wrap.innerHTML = "❌ Run <code>auto_fines_per_type_switches_20261012.sql</code> in Supabase.";
    return;
  }
  if (!rows.length) {
    wrap.textContent = "No automatic fine types found.";
    return;
  }
  const masterOff = !s.active;
  wrap.innerHTML = rows
    .map((r) => {
      const amount =
        r.amount_mode === "manual" || r.amount == null
          ? ""
          : ` <span style="color:#999;">${formatMoney(Number(r.amount) || 0)}</span>`;
      const waived = Number(r.waived_count || 0)
        ? ` <span style="color:#fc6;font-size:11px;">(${r.waived_count} waived)</span>`
        : "";
      return `<label style="display:flex;gap:6px;align-items:center;cursor:pointer;${masterOff ? "opacity:.6;" : ""}">
        <input type="checkbox" data-fine-switch="${escapeHtml(r.code)}"${r.enabled ? " checked" : ""}>
        <span>${escapeHtml(r.label)}${amount}${waived}</span>
      </label>`;
    })
    .join("");

  wrap.querySelectorAll("[data-fine-switch]").forEach((box) => {
    box.addEventListener("change", async () => {
      const code = box.getAttribute("data-fine-switch");
      box.disabled = true;
      setStatus("autoFinesStatus", "Saving…");
      const { data, error } = await supabase.rpc("admin_set_auto_fine_switch", {
        p_code: code,
        p_enabled: box.checked,
      });
      if (error) {
        box.checked = !box.checked;
        box.disabled = false;
        setStatus("autoFinesStatus", "❌ " + error.message, false);
        return;
      }
      renderAutoFines(data);
      const label = rows.find((r) => r.code === code)?.label || code;
      setStatus(
        "autoFinesStatus",
        box.checked ? `✅ ${label}: ON` : `✅ ${label}: OFF (waived)`
      );
    });
  });
}

async function loadAutoFines() {
  const { data, error } = await supabase.rpc("gpsl_auto_fines_status");
  if (error) console.warn("gpsl_auto_fines_status", error);
  renderAutoFines(error ? null : data);
}

async function setAutoFines(enabled) {
  const raw = document.getElementById("autoFinesLiveFrom")?.value || "";
  const liveFrom = !enabled && raw ? new Date(raw).toISOString() : null;
  const msg = enabled
    ? "Turn automatic fines ON? New offences will be charged from now (nothing retrospective)."
    : `Turn automatic fines OFF for an ease-in period?${
        liveFrom ? `\n\nThey will switch back on automatically at ${new Date(liveFrom).toLocaleString("en-GB")}.` : ""
      }`;
  if (!confirm(msg)) return;
  setStatus("autoFinesStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_set_auto_fines", {
    p_enabled: enabled,
    p_live_from: liveFrom,
  });
  if (error) {
    setStatus("autoFinesStatus", "❌ " + error.message, false);
    return;
  }
  renderAutoFines(data);
  setStatus("autoFinesStatus", enabled ? "✅ Automatic fines ON." : "✅ Automatic fines OFF (ease-in).");
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Size a <select> to the longest option label (plus padding for the dropdown arrow). */
function fitSelectToOptions(select, { pad = 36, min = 72, max = 640 } = {}) {
  if (!select) return;
  const probe = document.createElement("span");
  const cs = getComputedStyle(select);
  probe.style.cssText = [
    "position:absolute",
    "left:-9999px",
    "top:0",
    "visibility:hidden",
    "white-space:nowrap",
    `font:${cs.font}`,
    `letter-spacing:${cs.letterSpacing}`,
    `padding:0 ${cs.paddingLeft} ${cs.paddingRight}`,
  ].join(";");
  document.body.appendChild(probe);

  let widest = 0;
  for (const opt of select.options) {
    probe.textContent = opt.textContent || "";
    widest = Math.max(widest, probe.offsetWidth);
  }
  probe.remove();

  const width = Math.min(max, Math.max(min, widest + pad));
  select.style.width = `${width}px`;
}

function fillMonthSelect() {
  const sel = document.getElementById("fineFixtureMonth");
  if (!sel) return;
  sel.innerHTML =
    `<option value="">All months</option>` +
    GPSL_MONTH_ORDER.map(
      (m) => `<option value="${m}">${GPSL_MONTH_LABELS[m] || m}</option>`
    ).join("");
  fitSelectToOptions(sel, { min: 100, max: 220 });
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
    fitSelectToOptions(sel, { max: 900 });
    return;
  }

  sel.innerHTML = `<option value="">Loading…</option>`;
  fitSelectToOptions(sel, { max: 900 });

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
    fitSelectToOptions(sel, { max: 900 });
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
    fitSelectToOptions(sel, { max: 900 });
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
  fitSelectToOptions(sel, { max: 900 });
}

async function loadClubs() {
  const { data } = await supabase.from("Clubs").select("ShortName, Club").order("Club");
  const options = (data || [])
    .map((c) => `<option value="${c.ShortName}">${escapeHtml(c.Club || c.ShortName)}</option>`)
    .join("");
  const clubSel = document.getElementById("fineClubSelect");
  clubSel.innerHTML = options;
  fitSelectToOptions(clubSel, { min: 100, max: 360 });
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

function onVideoReport(t) {
  return videoReportCodes.has(t.code);
}

const AUTOMATED_TARIFFS = new Set([
  "match_mgmt_no_proposal",
  "match_late_arrangement",
  "match_response_deadline",
  "match_no_show_1",
  "match_no_show_2",
  "match_no_show_3",
  "match_no_show_strike_triple",
  "match_video_missing",
  "match_already_played_bypass",
  "match_manual_mutual_forfeit",
  "breach_squad_24_min",
  "breach_squad_hg_min",
  "breach_squad_u21_min",
  "breach_squad_star_cap",
  "squad_overflow_mv_release",
]);

const BROKEN_TARIFFS = new Set(["match_no_show_fixture_forfeit", "match_window_expiry"]);

function tariffCanCharge(t) {
  if (t.amount_mode === "manual") return true;
  if (t.code === "formation_player_drag") return true;
  return Number(t.amount) > 0;
}

function tariffWiring(t) {
  if (BROKEN_TARIFFS.has(t.code)) {
    return {
      charge: "Automated",
      state: "broken",
      mark: "✕",
      label: "Broken",
      why: "The forfeit helper charges this after writing the 0–3. The amount is 0, so the charge is rejected and the result rolls back.",
    };
  }
  if (t.code === "formation_player_drag") {
    return {
      charge: "Admin confirmed",
      state: "working",
      mark: "✓",
      label: "Working",
      why: "Staff approve the video report. The match is replayed or the result stands, with −1 point at 2 or more drags. No money is taken.",
    };
  }
  if (AUTOMATED_TARIFFS.has(t.code)) {
    return {
      charge: "Automated",
      state: "working",
      mark: "✓",
      label: "Working",
      why: "A job charges this. While automatic fines are off, the owner gets a would-have-been-fined note instead.",
    };
  }
  if (t.direction === "compensation") {
    return {
      charge: "Hand only",
      state: tariffCanCharge(t) ? "idle" : "broken",
      mark: tariffCanCharge(t) ? "○" : "✕",
      label: tariffCanCharge(t) ? "Not wired" : "Broken",
      why: tariffCanCharge(t)
        ? "A credit. Nothing pays it on its own. An admin applies it and types the amount when the row has none."
        : "No amount is set, so applying it is rejected.",
    };
  }
  if (onVideoReport(t)) {
    const ok = tariffCanCharge(t);
    return {
      charge: "Admin confirmed",
      state: ok ? "working" : "broken",
      mark: ok ? "✓" : "✕",
      label: ok ? "Working" : "Broken",
      why: ok
        ? "An opponent reports it on the video. Nothing is taken until staff approve."
        : "It is on the video report, but the amount is 0 so approval cannot charge it.",
    };
  }
  const ok = tariffCanCharge(t);
  const covered = COVERED_ELSEWHERE[t.code];
  return {
    charge: "Hand only",
    state: ok ? "idle" : "broken",
    mark: ok ? "○" : "✕",
    label: ok ? "Not wired" : "Broken",
    why: covered
      ? covered
      : ok
        ? "Nothing calls this. An admin can still apply it from this page."
        : "Nothing calls this, and the amount is 0 so a hand apply is rejected too.",
  };
}

const COVERED_ELSEWHERE = {
  breach_squad_28_max:
    "Going over 28 is charged as squad_overflow_mv_release (₿2.5m) when a signing forces a market-value release. This ₿5m row is never called.",
  breach_squad_30_max:
    "The squad cap in use is 28, charged as squad_overflow_mv_release. This 30-man row is never called.",
};

function videoReportCell(t) {
  if (onVideoReport(t)) {
    return {
      text: "Yes",
      cls: "on",
      why: "Owners can choose this on the match-video R button. It is charged when staff approve the report.",
    };
  }
  if (videoReportColumn && t.on_video_report) {
    return {
      text: "Ticked, hidden",
      cls: "off",
      why: "The video-report tick is on, but the R button only lists an active fine. A credit and the missing-video tariff stay off it.",
    };
  }
  return {
    text: "No",
    cls: "off",
    why: "Not on the match-video R button.",
  };
}

function setTariffFilter(next) {
  tariffFilter = next;
  for (const [id, value] of [
    ["tariffFilterAll", "all"],
    ["tariffFilterVideo", "video"],
    ["tariffFilterOther", "other"],
  ]) {
    const btn = document.getElementById(id);
    if (!btn) continue;
    const on = value === next;
    btn.setAttribute("aria-pressed", on ? "true" : "false");
    btn.classList.toggle("secondary", !on);
  }
  renderTariffList();
}

function normaliseTariffCode(raw) {
  return String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

async function loadTariffs() {
  const [tariffRes, reportRes] = await Promise.all([
    supabase.from("competition_fine_tariff").select("*").order("category").order("sort_order"),
    supabase.rpc("match_video_report_breach_codes"),
  ]);

  if (tariffRes.error) {
    setStatus(
      "fineTariffStatus",
      "❌ " + tariffRes.error.message + " — run competition_fines.sql",
      false
    );
    return;
  }

  tariffs = tariffRes.data || [];
  videoReportColumn = tariffs.length > 0 && Object.prototype.hasOwnProperty.call(tariffs[0], "on_video_report");
  videoReportCodes = new Set();
  if (!reportRes.error && Array.isArray(reportRes.data)) {
    for (const row of reportRes.data) {
      if (row?.code) videoReportCodes.add(row.code);
    }
  }

  const videoBox = document.getElementById("fineEditVideoReport");
  if (videoBox) {
    videoBox.disabled = !videoReportColumn;
    videoBox.title = videoReportColumn
      ? "Owners can report this fine from a match video."
      : "Run fine_tariff_video_report_20261106.sql to change this list.";
  }

  const pick = document.getElementById("fineTariffSelect");
  pick.innerHTML = tariffs
    .filter((t) => t.is_active)
    .map((t) => `<option value="${t.code}">${escapeHtml(tariffOptionLabel(t))}</option>`)
    .join("");
  fitSelectToOptions(pick, { min: 160, max: 560 });

  renderTariffList();
  onTariffPick();

  const reportNote = reportRes.error
    ? " Video-report list could not be loaded."
    : ` ${videoReportCodes.size} on the video report.`;
  const columnNote = videoReportColumn
    ? ""
    : " Run fine_tariff_video_report_20261106.sql to tick fines onto that list.";
  setStatus("fineTariffStatus", `${tariffs.length} tariff(s) loaded.${reportNote}${columnNote}`, !reportRes.error);
}

function renderTariffList() {
  const list = document.getElementById("fineTariffList");
  if (!list) return;
  if (!tariffs.length) {
    list.innerHTML = "<p class='note'>No tariffs — click Seed Excel tariffs, or add one above.</p>";
    return;
  }

  const opt = (value, label, current) =>
    `<option value="${value}"${value === current ? " selected" : ""}>${label}</option>`;
  const categories = ["matchday", "squad", "transfer", "manager", "compensation", "other"];
  const shown = tariffs.filter((t) => {
    if (tariffFilter === "video") return onVideoReport(t);
    if (tariffFilter === "other") return !onVideoReport(t);
    return true;
  });

  if (!shown.length) {
    list.innerHTML = "<p class='note'>Nothing in this filter.</p>";
    return;
  }

  list.innerHTML = shown
    .map((t) => {
      const amt =
        t.amount_mode === "manual" ? "manual" : formatMoney(Number(t.amount || 0));
      const code = escapeHtml(t.code);
      const onReport = onVideoReport(t);
      const wiring = tariffWiring(t);
      const videoCol = videoReportCell(t);
      const videoCheck = videoReportColumn
        ? `<div style="align-self:flex-end;"><label style="display:flex;gap:6px;align-items:center;"><input type="checkbox" data-f="on_video_report"${t.on_video_report ? " checked" : ""}> On the video report</label></div>`
        : "";
      return `
        <div class="challenge-admin-item fine-tariff-row" data-tariff-row="${code}" style="${t.is_active ? "" : "opacity:.6;"}${onReport ? "border-left:3px solid #e80;" : ""}">
          <div style="min-width:0;">
            <b>${escapeHtml(t.label)}</b>
            <span class="challenge-admin-meta">${code} · ${escapeHtml(t.category)} · ${escapeHtml(t.direction)} · ${amt}${t.is_active ? "" : " · inactive"}</span>
          </div>
          <div class="fine-charge" title="${escapeHtml(wiring.why)}">${escapeHtml(wiring.charge)}</div>
          <div class="fine-state ${wiring.state}" title="${escapeHtml(wiring.why)}">${wiring.mark} ${escapeHtml(wiring.label)}</div>
          <div class="fine-video ${videoCol.cls}" title="${escapeHtml(videoCol.why)}">${escapeHtml(videoCol.text)}</div>
          <div style="display:flex;gap:6px;">
            <button type="button" class="button fine-edit-btn" data-code="${code}">Edit</button>
            <button type="button" class="button secondary fine-delete-btn" data-code="${code}" style="color:#f88;">Delete</button>
          </div>
          <div class="fine-inline-edit" data-edit-for="${code}" hidden style="flex-basis:100%;margin-top:8px;">
            <div class="row gov-subsidy-row" style="flex-wrap:wrap;gap:8px;">
              <div><label>Label</label><input type="text" data-f="label" value="${escapeHtml(t.label)}" style="width:260px;"></div>
              <div><label>Category</label><select data-f="category">${categories
                .map((c) => opt(c, c[0].toUpperCase() + c.slice(1), t.category))
                .join("")}</select></div>
              <div><label>Direction</label><select data-f="direction">${opt("fine", "Fine (debit)", t.direction)}${opt(
                "compensation",
                "Compensation (credit)",
                t.direction
              )}</select></div>
              <div><label>Amount ₿</label><input type="number" data-f="amount" min="0" step="50000" style="width:120px;" value="${
                t.amount != null ? escapeHtml(String(t.amount)) : ""
              }"></div>
              <div><label>Mode</label><select data-f="amount_mode">${opt("fixed", "Fixed", t.amount_mode)}${opt(
                "manual",
                "Manual at apply",
                t.amount_mode
              )}</select></div>
              <div><label>Sort</label><input type="number" data-f="sort_order" style="width:70px;" value="${Number(t.sort_order) || 0}"></div>
              <div style="align-self:flex-end;"><label><input type="checkbox" data-f="is_active"${t.is_active ? " checked" : ""}> Active</label></div>
              ${videoCheck}
            </div>
            <div class="row" style="margin-top:8px;gap:6px;">
              <button type="button" class="button fine-inline-save" data-code="${code}">Save</button>
              <button type="button" class="button secondary fine-inline-cancel" data-code="${code}">Cancel</button>
            </div>
          </div>
        </div>
      `;
    })
    .join("");

  list.querySelectorAll(".fine-edit-btn").forEach((btn) => {
    btn.onclick = () => {
      const box = list.querySelector(`[data-edit-for="${CSS.escape(btn.dataset.code)}"]`);
      if (box) box.hidden = !box.hidden;
    };
  });
  list.querySelectorAll(".fine-inline-cancel").forEach((btn) => {
    btn.onclick = () => {
      const box = list.querySelector(`[data-edit-for="${CSS.escape(btn.dataset.code)}"]`);
      if (box) box.hidden = true;
    };
  });
  list.querySelectorAll(".fine-inline-save").forEach((btn) => {
    btn.onclick = () => saveInlineTariff(btn.dataset.code);
  });
  list.querySelectorAll(".fine-delete-btn").forEach((btn) => {
    btn.onclick = () => deleteTariff(btn.dataset.code);
  });
}

async function saveInlineTariff(code) {
  const box = document.querySelector(`[data-edit-for="${CSS.escape(code)}"]`);
  if (!box) return;
  const f = (name) => box.querySelector(`[data-f="${name}"]`);
  const label = f("label").value.trim();
  if (!label) {
    setStatus("fineTariffStatus", "Label required.", false);
    return;
  }
  const amountVal = f("amount").value;
  const videoEl = f("on_video_report");
  const wantedVideo = videoEl ? videoEl.checked : false;
  setStatus("fineTariffStatus", "Saving…");
  const payload = {
    code,
    label,
    category: f("category").value,
    direction: f("direction").value,
    amount: amountVal === "" ? null : Number(amountVal),
    amount_mode: f("amount_mode").value,
    is_active: f("is_active").checked,
    sort_order: Number(f("sort_order").value) || 0,
  };
  if (videoReportColumn) payload.on_video_report = wantedVideo;
  const { error } = await supabase.rpc("competition_admin_save_fine_tariff", {
    p_tariff: payload,
  });
  if (error) {
    setStatus("fineTariffStatus", "❌ " + error.message, false);
    return;
  }
  await loadTariffs();
  await loadAutoFines();
  const videoNote =
    wantedVideo && videoReportColumn && videoReportCodes.has(code)
      ? " It is on the video report."
      : wantedVideo && videoReportColumn
        ? " Saved. It stays off the video report until it is an active fine."
        : "";
  setStatus("fineTariffStatus", `✅ Saved ${label}.${videoNote}`, true);
}

async function deleteTariff(code) {
  const t = tariffs.find((x) => x.code === code);
  if (!confirm(`Delete tariff "${t?.label || code}" (${code})?\n\nIf fines have already been charged under it, it will be deactivated instead so history keeps its record.`)) {
    return;
  }
  setStatus("fineTariffStatus", "Deleting…");
  const { data, error } = await supabase.rpc("admin_delete_fine_tariff", { p_code: code });
  if (error) {
    const msg = String(error.message || "");
    setStatus(
      "fineTariffStatus",
      msg.includes("admin_delete_fine_tariff")
        ? "❌ Run fine_tariff_admin_delete_20261012.sql in Supabase."
        : "❌ " + msg,
      false
    );
    return;
  }
  if (!data?.ok) {
    if (data?.reason === "used_by_system") {
      setStatus(
        "fineTariffStatus",
        `❌ ${code} is used by automatic fines (${(data.used_by || []).join(", ")}). Untick it under "Fine types" to stop charging it instead.`,
        false
      );
    } else {
      setStatus("fineTariffStatus", "❌ Could not delete (" + (data?.reason || "unknown") + ").", false);
    }
    return;
  }
  await loadTariffs();
  await loadAutoFines();
  setStatus(
    "fineTariffStatus",
    data.action === "deactivated"
      ? `✅ ${code} deactivated — ${data.applied_count} fine(s) already applied under it, so it's kept for history.`
      : `✅ ${code} deleted.`,
    true
  );
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
  const videoBox = document.getElementById("fineEditVideoReport");
  if (videoBox) videoBox.checked = false;
  setStatus("fineFormStatus", "");
}

async function saveTariff() {
  const code = normaliseTariffCode(document.getElementById("fineEditCodeInput").value);
  const label = document.getElementById("fineEditLabel").value.trim();
  if (!code || !label) {
    setStatus("fineFormStatus", "Code and label required. Use letters, numbers and underscores.", false);
    return;
  }
  document.getElementById("fineEditCodeInput").value = code;

  const amountVal = document.getElementById("fineEditAmount").value;
  const wantedVideo = document.getElementById("fineEditVideoReport")?.checked === true;
  const existing = tariffs.find((t) => t.code === code);
  const nextSort =
    existing != null
      ? Number(existing.sort_order) || 0
      : Math.max(0, ...tariffs.map((t) => Number(t.sort_order) || 0)) + 10;
  setStatus("fineFormStatus", "Saving…");
  const payload = {
    code,
    label,
    category: document.getElementById("fineEditCategory").value,
    direction: document.getElementById("fineEditDirection").value,
    amount: amountVal === "" ? null : Number(amountVal),
    amount_mode: document.getElementById("fineEditMode").value,
    is_active: existing?.is_active ?? true,
    sort_order: nextSort,
  };
  if (videoReportColumn) payload.on_video_report = wantedVideo;
  const { error } = await supabase.rpc("competition_admin_save_fine_tariff", {
    p_tariff: payload,
  });

  if (error) {
    setStatus("fineFormStatus", "❌ " + error.message, false);
    return;
  }

  await loadTariffs();
  clearFineForm();
  if (wantedVideo && !videoReportColumn) {
    setStatus(
      "fineFormStatus",
      `✅ Saved ${label}. Run fine_tariff_video_report_20261106.sql before it can be ticked onto the video report.`,
      true
    );
    return;
  }
  const onReport = videoReportCodes.has(code);
  setStatus(
    "fineFormStatus",
    onReport
      ? `✅ Saved ${label}. It is on the video report.`
      : `✅ Saved ${label}.`,
    true
  );
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
      const waived = r.waived
        ? ` <span style="color:#fc6;font-size:12px;">WAIVED (ease-in)</span>`
        : "";
      return `<div class="challenge-admin-item">
        <span><b>${r.club_short_name}</b> ${sign}${formatMoney(r.amount)} — ${label}${waived}
        <span class="challenge-admin-meta">${new Date(r.applied_at).toLocaleString("en-GB")}</span></span>
      </div>`;
    })
    .join("");
}
