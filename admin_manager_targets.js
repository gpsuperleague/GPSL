import { supabase, initGlobal, isGpslAdminUser } from "./global.js";

const DIVISIONS = ["superleague", "championship_a", "championship_b"];
const KINDS = ["max_position", "promotion", "avoid_relegation"];

let rows = [];

function render() {
  const body = document.getElementById("targetsBody");
  if (!body) return;
  body.innerHTML = rows
    .map(
      (r, idx) => `<tr data-idx="${idx}">
      <td><input type="number" class="min_rating" value="${r.min_rating}" min="1" max="99" style="width:60px"></td>
      <td><input type="number" class="max_rating" value="${r.max_rating}" min="1" max="99" style="width:60px"></td>
      <td><select class="division">${DIVISIONS.map((d) => `<option value="${d}" ${r.division === d ? "selected" : ""}>${d}</option>`).join("")}</select></td>
      <td><select class="target_kind">${KINDS.map((k) => `<option value="${k}" ${r.target_kind === k ? "selected" : ""}>${k}</option>`).join("")}</select></td>
      <td><input type="number" class="target_value" value="${r.target_value ?? ""}" style="width:60px" placeholder="—"></td>
      <td><input type="text" class="label" value="${r.label ?? ""}" style="width:220px"></td>
      <td><input type="number" class="sort_order" value="${r.sort_order ?? 0}" style="width:50px"></td>
      <td>
        <button class="button save-row">Save</button>
        <button class="button delete-row">Delete</button>
      </td>
    </tr>`
    )
    .join("");

  body.querySelectorAll(".save-row").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tr = btn.closest("tr");
      const idx = Number(tr.dataset.idx);
      const payload = readRow(tr);
      payload.id = rows[idx].id;
      const { error } = await supabase.rpc("admin_upsert_manager_rating_target", {
        p_payload: payload,
      });
      if (error) {
        document.getElementById("adminError").textContent = error.message;
        return;
      }
      await loadRows();
    });
  });

  body.querySelectorAll(".delete-row").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tr = btn.closest("tr");
      const idx = Number(tr.dataset.idx);
      const id = rows[idx].id;
      if (!id) {
        rows.splice(idx, 1);
        render();
        return;
      }
      const { error } = await supabase.rpc("admin_delete_manager_rating_target", { p_id: id });
      if (error) {
        document.getElementById("adminError").textContent = error.message;
        return;
      }
      await loadRows();
    });
  });
}

function readRow(tr) {
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

async function loadRows() {
  const { data, error } = await supabase
    .from("manager_rating_targets")
    .select("*")
    .order("sort_order")
    .order("min_rating", { ascending: false });

  if (error) {
    document.getElementById("adminError").textContent = error.message;
    return;
  }
  rows = data || [];
  document.getElementById("adminError").textContent = "";
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const { data: { user } } = await supabase.auth.getUser();
  if (!isGpslAdminUser(user)) {
    document.getElementById("adminError").textContent = "Admin only.";
    return;
  }

  document.getElementById("addRowBtn")?.addEventListener("click", () => {
    rows.push({
      min_rating: 80,
      max_rating: 84,
      division: "superleague",
      target_kind: "max_position",
      target_value: 6,
      label: "",
      sort_order: 0,
    });
    render();
  });

  await loadRows();
});
