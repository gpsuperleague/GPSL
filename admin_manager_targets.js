import { initAdminPage, primeAdminPageChrome, supabase } from "./admin_common.js";

primeAdminPageChrome();

let rows = [];

function bandInputs(row, minKey, maxKey) {
  const min = row[minKey];
  const max = row[maxKey];
  if (min == null && max == null) {
    return `<td colspan="2" class="na">—</td>`;
  }
  return `<td><input type="number" class="${minKey}" value="${min ?? ""}" min="0" max="99"></td>
    <td><input type="number" class="${maxKey}" value="${max ?? ""}" min="0" max="99"></td>`;
}

function render() {
  const body = document.getElementById("expectancyBody");
  if (!body) return;

  body.innerHTML = rows
    .map(
      (r, idx) => `<tr data-idx="${idx}">
      <td><b>${r.proficiency}</b></td>
      ${bandInputs(r, "boost1_min", "boost1_max")}
      ${bandInputs(r, "boost2_min", "boost2_max")}
      ${bandInputs(r, "boost3_min", "boost3_max")}
      <td><button type="button" class="button save-row">Save</button></td>
    </tr>`
    )
    .join("");

  body.querySelectorAll(".save-row").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tr = btn.closest("tr");
      const idx = Number(tr.dataset.idx);
      const payload = readRow(tr, rows[idx].proficiency);
      const { error } = await supabase.rpc("admin_upsert_manager_proficiency_expectancy", {
        p_payload: payload,
      });
      const errEl = document.getElementById("adminError");
      if (error) {
        if (errEl) errEl.textContent = error.message;
        return;
      }
      if (errEl) errEl.textContent = "";
      await loadRows();
    });
  });
}

function readRow(tr, proficiency) {
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

function normalizeRow(row) {
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

async function loadRows() {
  const { data, error } = await supabase
    .from("manager_proficiency_expectancy")
    .select("*")
    .order("proficiency");

  const errEl = document.getElementById("adminError");
  if (error) {
    if (errEl) {
      errEl.textContent = error.message.includes("manager_proficiency_expectancy")
        ? "Run supabase/sql/patches/manager_squad_boost_impact.sql first."
        : error.message;
    }
    return;
  }
  rows = (data || []).map(normalizeRow);
  if (errEl) errEl.textContent = "";
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  await loadRows();
});
