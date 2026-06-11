import { initAdminPage, primeAdminPageChrome, supabase } from "./admin_common.js";

primeAdminPageChrome();

const DIVISIONS = ["superleague", "championship_a", "championship_b"];
const KINDS = ["max_position", "promotion", "avoid_relegation"];

let targetRows = [];
let chartRows = [];

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function renderTargets() {
  const body = document.getElementById("targetsBody");
  if (!body) return;

  body.innerHTML = targetRows
    .map(
      (r, idx) => `<tr data-idx="${idx}">
      <td><input type="number" class="min_rating inp-num" value="${r.min_rating}" min="1" max="99"></td>
      <td><input type="number" class="max_rating inp-num" value="${r.max_rating}" min="1" max="99"></td>
      <td><select class="division">${DIVISIONS.map((d) => `<option value="${d}" ${r.division === d ? "selected" : ""}>${d}</option>`).join("")}</select></td>
      <td><select class="target_kind">${KINDS.map((k) => `<option value="${k}" ${r.target_kind === k ? "selected" : ""}>${k}</option>`).join("")}</select></td>
      <td><input type="number" class="target_value inp-num" value="${r.target_value ?? ""}" placeholder="—"></td>
      <td class="col-label"><input type="text" class="label" value="${escapeHtml(r.label ?? "")}"></td>
      <td><input type="number" class="sort_order inp-order" value="${r.sort_order ?? 0}"></td>
      <td class="col-actions">
        <div class="row-actions">
          <button type="button" class="button save-target">Save</button>
          <button type="button" class="button delete-target">Delete</button>
        </div>
      </td>
    </tr>`
    )
    .join("");

  body.querySelectorAll(".save-target").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tr = btn.closest("tr");
      const idx = Number(tr.dataset.idx);
      const payload = readTargetRow(tr);
      payload.id = targetRows[idx].id;
      const { error } = await supabase.rpc("admin_upsert_manager_rating_target", {
        p_payload: payload,
      });
      setError(error?.message);
      if (!error) await loadTargetRows();
    });
  });

  body.querySelectorAll(".delete-target").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tr = btn.closest("tr");
      const idx = Number(tr.dataset.idx);
      const id = targetRows[idx].id;
      if (!id) {
        targetRows.splice(idx, 1);
        renderTargets();
        return;
      }
      const { error } = await supabase.rpc("admin_delete_manager_rating_target", { p_id: id });
      setError(error?.message);
      if (!error) await loadTargetRows();
    });
  });
}

function readTargetRow(tr) {
  return {
    min_rating: Number(tr.querySelector(".min_rating").value),
    max_rating: Number(tr.querySelector(".max_rating").value),
    division: tr.querySelector(".division").value,
    target_kind: tr.querySelector(".target_kind").value,
    target_value: tr.querySelector(".target_value").value || null,
    label: tr.querySelector(".label").value,
    sort_order: Number(tr.querySelector(".sort_order").value) || 0,
  };
}

function bandInputs(row, minKey, maxKey) {
  const min = row[minKey];
  const max = row[maxKey];
  if (min == null && max == null) {
    return `<td colspan="2" class="na">—</td>`;
  }
  return `<td><input type="number" class="${minKey}" value="${min ?? ""}" min="0" max="99"></td>
    <td><input type="number" class="${maxKey}" value="${max ?? ""}" min="0" max="99"></td>`;
}

function renderChart() {
  const body = document.getElementById("expectancyBody");
  if (!body) return;

  body.innerHTML = chartRows
    .map(
      (r, idx) => `<tr data-idx="${idx}">
      <td><b>${r.proficiency}</b></td>
      ${bandInputs(r, "boost1_min", "boost1_max")}
      ${bandInputs(r, "boost2_min", "boost2_max")}
      ${bandInputs(r, "boost3_min", "boost3_max")}
      <td><button type="button" class="button save-chart">Save</button></td>
    </tr>`
    )
    .join("");

  body.querySelectorAll(".save-chart").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tr = btn.closest("tr");
      const idx = Number(tr.dataset.idx);
      const payload = readChartRow(tr, chartRows[idx].proficiency);
      const { error } = await supabase.rpc("admin_upsert_manager_proficiency_expectancy", {
        p_payload: payload,
      });
      setError(error?.message);
      if (!error) await loadChartRows();
    });
  });
}

function readChartRow(tr, proficiency) {
  const num = (sel) => {
    const v = tr.querySelector(sel)?.value;
    return v === "" || v == null ? null : Number(v);
  };
  return {
    proficiency,
    boost1_min: num(".boost1_min"),
    boost1_max: num(".boost1_max"),
    boost2_min: num(".boost2_min"),
    boost2_max: num(".boost2_max"),
    boost3_min: num(".boost3_min"),
    boost3_max: num(".boost3_max"),
  };
}

function normalizeChartRow(row) {
  return {
    proficiency: row.proficiency,
    boost1_min: row.boost1_min ?? row.tier1_min,
    boost1_max: row.boost1_max ?? row.tier1_max,
    boost2_min: row.boost2_min ?? row.tier2_min,
    boost2_max: row.boost2_max ?? row.tier2_max,
    boost3_min: row.boost3_min ?? row.tier3_min,
    boost3_max: row.boost3_max ?? row.tier3_max,
  };
}

function setError(msg) {
  const el = document.getElementById("adminError");
  if (el) el.textContent = msg || "";
}

async function loadTargetRows() {
  const { data, error } = await supabase
    .from("manager_rating_targets")
    .select("*")
    .order("sort_order")
    .order("min_rating", { ascending: false });

  if (error) {
    setError(error.message);
    return;
  }
  targetRows = data || [];
  renderTargets();
}

async function loadChartRows() {
  const { data, error } = await supabase
    .from("manager_proficiency_expectancy")
    .select("*")
    .order("proficiency");

  if (error) {
    if (error.message.includes("manager_proficiency_expectancy")) {
      setError("Run supabase/sql/patches/manager_squad_boost_impact.sql for the impact chart.");
    } else {
      setError(error.message);
    }
    return;
  }
  chartRows = (data || []).map(normalizeChartRow);
  renderChart();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();

  document.getElementById("addRowBtn")?.addEventListener("click", () => {
    targetRows.push({
      min_rating: 80,
      max_rating: 84,
      division: "superleague",
      target_kind: "max_position",
      target_value: 6,
      label: "",
      sort_order: 0,
    });
    renderTargets();
  });

  await Promise.all([loadTargetRows(), loadChartRows()]);
});
