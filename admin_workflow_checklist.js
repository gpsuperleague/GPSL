import { initAdminPage, primeAdminPageChrome, setStatus, supabase, whenDomReady } from "./admin_common.js";
import {
  adminMainNavHref,
  getAdminWorkflowChecklist,
} from "./admin_main_nav.js";

primeAdminPageChrome();

const LOCAL_PREFIX = "gpsl_admin_workflow_checklist:";

/** @type {number|null} */
let seasonId = null;
/** @type {string} */
let seasonLabel = "—";
/** @type {Map<string, boolean>} */
let doneMap = new Map();
/** @type {"db"|"local"} */
let storageMode = "local";
let hideDone = false;

whenDomReady(async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("wfExpandAll")?.addEventListener("click", () => setAllDetails(true));
  document.getElementById("wfCollapseAll")?.addEventListener("click", () => setAllDetails(false));
  document.getElementById("wfHideDone")?.addEventListener("click", () => {
    hideDone = !hideDone;
    const btn = document.getElementById("wfHideDone");
    if (btn) btn.textContent = hideDone ? "Show completed" : "Hide completed";
    render();
  });

  await loadSeason();
  await loadDoneState();
  render();
});

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function localStorageKey() {
  return `${LOCAL_PREFIX}${seasonId ?? "none"}`;
}

function readLocalDone() {
  try {
    const raw = localStorage.getItem(localStorageKey());
    if (!raw) return new Map();
    const obj = JSON.parse(raw);
    return new Map(Object.entries(obj).map(([k, v]) => [k, Boolean(v)]));
  } catch {
    return new Map();
  }
}

function writeLocalDone() {
  const obj = Object.fromEntries(doneMap);
  localStorage.setItem(localStorageKey(), JSON.stringify(obj));
}

async function loadSeason() {
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label")
    .eq("is_current", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    setStatus("wfStatus", `Could not load season: ${error.message}`, false);
    return;
  }
  seasonId = data?.id ?? null;
  seasonLabel = data?.label || (seasonId ? `Season ${seasonId}` : "No current season");
  const el = document.getElementById("wfSeasonLabel");
  if (el) el.textContent = `Season: ${seasonLabel}`;
}

async function loadDoneState() {
  doneMap = new Map();
  if (!seasonId) {
    storageMode = "local";
    doneMap = readLocalDone();
    return;
  }

  const { data, error } = await supabase
    .from("admin_workflow_checklist")
    .select("task_key, is_done")
    .eq("season_id", seasonId);

  if (error) {
    storageMode = "local";
    doneMap = readLocalDone();
    setStatus(
      "wfStatus",
      `Using browser-only ticks (${error.message}). Run admin_workflow_checklist.sql for shared storage.`,
      false
    );
    return;
  }

  storageMode = "db";
  for (const row of data || []) {
    doneMap.set(row.task_key, Boolean(row.is_done));
  }
  setStatus("wfStatus", "Shared checklist loaded for this season.", true);
}

function allTasks() {
  const out = [];
  for (const section of getAdminWorkflowChecklist()) {
    for (const block of section.blocks) {
      for (const item of block.items) out.push(item);
    }
  }
  return out;
}

function updateSummary() {
  const tasks = allTasks();
  const total = tasks.length;
  const done = tasks.filter((t) => doneMap.get(t.taskKey)).length;
  const doneEl = document.getElementById("wfDoneCount");
  const totalEl = document.getElementById("wfTotalCount");
  const fill = document.getElementById("wfProgressFill");
  if (doneEl) doneEl.textContent = String(done);
  if (totalEl) totalEl.textContent = String(total);
  if (fill) fill.style.width = total ? `${Math.round((done / total) * 100)}%` : "0%";
}

function setAllDetails(open) {
  document.querySelectorAll("#wfRoot details").forEach((el) => {
    el.open = open;
  });
}

async function setTaskDone(taskKey, isDone) {
  doneMap.set(taskKey, isDone);

  if (storageMode === "db" && seasonId != null) {
    const { error } = await supabase.rpc("admin_workflow_checklist_set", {
      p_season_id: seasonId,
      p_task_key: taskKey,
      p_is_done: isDone,
    });
    if (error) {
      storageMode = "local";
      writeLocalDone();
      setStatus(
        "wfStatus",
        `Saved locally (${error.message}). Run admin_workflow_checklist.sql for shared ticks.`,
        false
      );
      render();
      return;
    }
    setStatus("wfStatus", isDone ? "Marked done." : "Marked not done.", true);
    render();
    return;
  }

  writeLocalDone();
  setStatus("wfStatus", "Saved in this browser.", true);
  render();
}

function render() {
  const root = document.getElementById("wfRoot");
  if (!root) return;

  const openIds = new Set(
    [...root.querySelectorAll("details[data-section]")]
      .filter((d) => d.open)
      .map((d) => d.dataset.section)
  );
  const hadDetails = Boolean(root.querySelector("details[data-section]"));

  const sections = getAdminWorkflowChecklist();
  let html = "";

  for (const section of sections) {
    const sectionTasks = section.blocks.flatMap((b) => b.items);
    const sectionDone = sectionTasks.filter((t) => doneMap.get(t.taskKey)).length;
    const openAttr = !hadDetails || openIds.has(section.id) ? " open" : "";
    html += `<details class="wf-section"${openAttr} data-section="${escapeHtml(section.id)}">`;
    html += `<summary><h2>${escapeHtml(section.label)} <span style="color:#888;font-weight:400;font-size:13px">(${sectionDone}/${sectionTasks.length})</span></h2></summary>`;

    for (const block of section.blocks) {
      if (block.groupLabel) {
        html += `<div class="wf-group-label">${escapeHtml(block.groupLabel)}</div>`;
      }
      html += `<ul class="wf-list">`;
      for (const item of block.items) {
        const done = Boolean(doneMap.get(item.taskKey));
        const href = adminMainNavHref(item);
        const hidden = hideDone && done ? " hidden" : "";
        html += `<li class="wf-item${done ? " done" : ""}"${hidden} data-task-key="${escapeHtml(item.taskKey)}">`;
        html += `<input type="checkbox" ${done ? "checked" : ""} aria-label="Mark ${escapeHtml(item.label)} done">`;
        html += `<div class="wf-body">`;
        html += `<div class="wf-label">${escapeHtml(item.label)}</div>`;
        html += `<div class="wf-meta"><a href="${escapeHtml(href)}">Open task</a></div>`;
        html += `</div></li>`;
      }
      html += `</ul>`;
    }

    html += `</details>`;
  }

  root.innerHTML = html;
  updateSummary();

  root.querySelectorAll(".wf-item input[type='checkbox']").forEach((cb) => {
    cb.addEventListener("change", async () => {
      const li = cb.closest("[data-task-key]");
      const key = li?.getAttribute("data-task-key");
      if (!key) return;
      cb.disabled = true;
      try {
        await setTaskDone(key, cb.checked);
      } finally {
        cb.disabled = false;
      }
    });
  });
}
