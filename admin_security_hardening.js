/**
 * Admin → Testing → Security hardening checklist.
 * Persists ticks in Supabase when patch applied; else this browser only.
 */
import { initAdminPage, primeAdminPageChrome, setStatus, supabase, whenDomReady } from "./admin_common.js";

primeAdminPageChrome();

const LOCAL_KEY = "gpsl_admin_security_hardening_checklist";

/** @type {Map<string, boolean>} */
let doneMap = new Map();
/** @type {"db"|"local"} */
let storageMode = "local";
let hideDone = false;

/**
 * Audit plan phases — keep in sync with gpsl-security-audit.canvas.tsx plan.
 * @type {{ id: string, label: string, risk: string, riskClass: string, lead?: string, items: { taskKey: string, label: string, note?: string, href?: string, hrefLabel?: string }[] }[]}
 */
export const SECURITY_HARDENING_PHASES = [
  {
    id: "phase1",
    label: "Phase 1 · Immediate (safe-first)",
    risk: "Done in repo",
    riskClass: "done-phase",
    lead: "Applied via security_hardening_safe.sql. Tick when verified in prod.",
    items: [
      {
        taskKey: "p1_discord_invoke_key",
        label: "Discord invoke_key never exposed to / written from the browser",
        note: "Get RPCs return has_key only; set RPCs ignore browser keys; column SELECT revoked.",
        href: "admin_discord_news.html",
        hrefLabel: "Discord News",
      },
      {
        taskKey: "p1_revoke_dangerous_rpcs",
        label: "Revoke authenticated EXECUTE on dangerous RPCs",
        note: "transferengine_run / _report, prize_grant_inventory_item, club_loan_reverse_premature_collections, owner_inbox_notify_all_clubs → service_role only; admin_transferengine_run kept.",
      },
      {
        taskKey: "p1_escape_html",
        label: "escapeHtml on high-risk auction / index display paths",
      },
      {
        taskKey: "p1_delete_transfer_engine_js",
        label: "Remove unused transferEngine.js",
      },
      {
        taskKey: "p1_verify_auto_flush",
        label: "Verify Discord News auto-flush with invoke_key (queue + test)",
        href: "admin_discord_news.html",
        hrefLabel: "Discord News",
      },
    ],
  },
  {
    id: "phase2",
    label: "Phase 2 · Quick SQL",
    risk: "Low breakage",
    riskClass: "low",
    lead: "Deny-by-default on supporting tables; tighten grants; confirm live matches repo.",
    items: [
      {
        taskKey: "p2_bank_rls",
        label: "ENABLE RLS deny-by-default on bank / treasury tables",
        note: "e.g. gpsl_bank_account, bank_ledger — keep access via existing views/RPCs.",
      },
      {
        taskKey: "p2_injury_quota_rls",
        label: "ENABLE RLS on injury / discipline / scheduling-quota tables",
        note: "competition_injury_*, suspensions, month_reschedule_use, emergency_drop_use, etc.",
      },
      {
        taskKey: "p2_least_privilege_grants",
        label: "Least-privilege GRANTs on those tables",
      },
      {
        taskKey: "p2_confirm_live_privileges",
        label: "Confirm live DB privileges match the repo map",
        note: "SQL Editor: relrowsecurity = false inventory; probe EXECUTE as non-admin.",
      },
    ],
  },
  {
    id: "phase3",
    label: "Phase 3 · Draft bids → RPCs",
    risk: "Low–medium",
    riskClass: "medium",
    lead: "Same pattern as club auction. Keep triggers as defense in depth.",
    items: [
      {
        taskKey: "p3_player_draft_place_bid_rpc",
        label: "Player draft: place-bid via RPC (stop client inserts)",
        note: "UI stays the same; test a full draft window thoroughly.",
      },
      {
        taskKey: "p3_manager_draft_place_bid_rpc",
        label: "Manager draft: place-bid via RPC (stop client inserts)",
      },
      {
        taskKey: "p3_keep_triggers",
        label: "Confirm bid triggers still enforce rules after RPC migration",
      },
    ],
  },
  {
    id: "phase4",
    label: "Phase 4 · Legacy core RLS",
    risk: "Higher — staged",
    riskClass: "high",
    lead: "Read where intentional; writes via RPCs. Needs regression on every .from() path.",
    items: [
      {
        taskKey: "p4_clubs_players_rls",
        label: "Programmatic RLS on Clubs + Players",
      },
      {
        taskKey: "p4_transfer_listings_bids_rls",
        label: "RLS on Player_Transfer_Listings + Player_Transfer_Bids",
      },
      {
        taskKey: "p4_finances_history_rls",
        label: "RLS on Club_Finances + Transfer_History",
      },
      {
        taskKey: "p4_staged_rollout_regression",
        label: "Staged rollout + regression (squads, market, finances, admin)",
      },
    ],
  },
  {
    id: "phase5",
    label: "Phase 5 · Hygiene",
    risk: "Low",
    riskClass: "low",
    lead: "Frontend consistency and admin identity hardening.",
    items: [
      {
        taskKey: "p5_broader_escape_html",
        label: "Shared escapeHtml on remaining owner tags / names / error.message paths",
      },
      {
        taskKey: "p5_server_admin_gates",
        label: "Don’t rely on client-only admin HTML gates — every privileged RPC uses is_gpsl_admin()",
      },
      {
        taskKey: "p5_multi_admin_mods",
        label: "Multi-admin via gpsl_site_mods / role table (not one hard-coded email)",
      },
      {
        taskKey: "p5_post_club_ledger",
        label: "Confirm post_club_ledger EXECUTE locked down (service_role / wrappers only)",
      },
    ],
  },
];

whenDomReady(async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("shExpandAll")?.addEventListener("click", () => setAllDetails(true));
  document.getElementById("shCollapseAll")?.addEventListener("click", () => setAllDetails(false));
  document.getElementById("shHideDone")?.addEventListener("click", () => {
    hideDone = !hideDone;
    const btn = document.getElementById("shHideDone");
    if (btn) btn.textContent = hideDone ? "Show completed" : "Hide completed";
    render();
  });
  document.getElementById("shClearAll")?.addEventListener("click", () => clearAllTicks());

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

function readLocalDone() {
  try {
    const raw = localStorage.getItem(LOCAL_KEY);
    if (!raw) return new Map();
    const obj = JSON.parse(raw);
    return new Map(Object.entries(obj).map(([k, v]) => [k, Boolean(v)]));
  } catch {
    return new Map();
  }
}

function writeLocalDone() {
  const obj = Object.fromEntries(doneMap);
  localStorage.setItem(LOCAL_KEY, JSON.stringify(obj));
}

function allTasks() {
  return SECURITY_HARDENING_PHASES.flatMap((p) => p.items);
}

function updateStorageLabel() {
  const el = document.getElementById("shStorageLabel");
  if (!el) return;
  el.textContent =
    storageMode === "db" ? "Shared (Supabase)" : "This browser only";
}

async function clearAllTicks() {
  if (
    !confirm(
      "Clear ALL security hardening ticks?\n\nThis cannot be undone."
    )
  ) {
    return;
  }

  const keys = allTasks().map((t) => t.taskKey);
  doneMap = new Map();

  if (storageMode === "db") {
    for (const key of keys) {
      const { error } = await supabase.rpc("admin_security_hardening_checklist_set", {
        p_task_key: key,
        p_is_done: false,
      });
      if (error) {
        setStatus("shStatus", `Clear failed: ${error.message}`, false);
        await loadDoneState();
        render();
        return;
      }
    }
    setStatus("shStatus", "All ticks cleared.", true);
  } else {
    writeLocalDone();
    setStatus("shStatus", "All ticks cleared (this browser).", true);
  }
  render();
}

async function migrateLocalTicksToDb(localDone) {
  if (!localDone?.size) return 0;
  let migrated = 0;
  for (const [taskKey, isDone] of localDone) {
    if (!isDone) continue;
    if (doneMap.get(taskKey)) continue;
    const { error } = await supabase.rpc("admin_security_hardening_checklist_set", {
      p_task_key: taskKey,
      p_is_done: true,
    });
    if (error) {
      setStatus(
        "shStatus",
        `Shared storage OK, but could not import browser ticks (${error.message}).`,
        false
      );
      return migrated;
    }
    doneMap.set(taskKey, true);
    migrated += 1;
  }
  if (migrated > 0) {
    try {
      localStorage.removeItem(LOCAL_KEY);
    } catch {
      /* ignore */
    }
  }
  return migrated;
}

async function loadDoneState() {
  doneMap = new Map();
  const localDone = readLocalDone();

  const { data, error } = await supabase
    .from("admin_security_hardening_checklist")
    .select("task_key, is_done");

  if (error) {
    storageMode = "local";
    doneMap = localDone;
    updateStorageLabel();
    setStatus(
      "shStatus",
      `Browser-only mode. Run admin_security_hardening_checklist.sql for shared ticks.`,
      false
    );
    return;
  }

  storageMode = "db";
  for (const row of data || []) {
    doneMap.set(row.task_key, Boolean(row.is_done));
  }

  const migrated = await migrateLocalTicksToDb(localDone);
  updateStorageLabel();
  if (migrated > 0) {
    setStatus(
      "shStatus",
      `Shared checklist loaded — imported ${migrated} tick(s) from this browser.`,
      true
    );
    return;
  }

  setStatus("shStatus", "Shared checklist loaded (saved in Supabase).", true);
}

function updateSummary() {
  const tasks = allTasks();
  const total = tasks.length;
  const done = tasks.filter((t) => doneMap.get(t.taskKey)).length;
  const doneEl = document.getElementById("shDoneCount");
  const totalEl = document.getElementById("shTotalCount");
  const fill = document.getElementById("shProgressFill");
  if (doneEl) doneEl.textContent = String(done);
  if (totalEl) totalEl.textContent = String(total);
  if (fill) fill.style.width = total ? `${Math.round((done / total) * 100)}%` : "0%";
}

function setAllDetails(open) {
  document.querySelectorAll("#shRoot details").forEach((el) => {
    el.open = open;
  });
}

async function setTaskDone(taskKey, isDone) {
  doneMap.set(taskKey, isDone);

  if (storageMode === "db") {
    const { error } = await supabase.rpc("admin_security_hardening_checklist_set", {
      p_task_key: taskKey,
      p_is_done: isDone,
    });
    if (error) {
      storageMode = "local";
      writeLocalDone();
      updateStorageLabel();
      setStatus(
        "shStatus",
        `Saved locally (${error.message}). Run admin_security_hardening_checklist.sql for shared ticks.`,
        false
      );
      render();
      return;
    }
    setStatus("shStatus", isDone ? "Marked done." : "Marked not done.", true);
    render();
    return;
  }

  writeLocalDone();
  setStatus("shStatus", "Saved in this browser.", true);
  render();
}

function render() {
  const root = document.getElementById("shRoot");
  if (!root) return;

  const openIds = new Set(
    [...root.querySelectorAll("details[data-phase]")]
      .filter((d) => d.open)
      .map((d) => d.dataset.phase)
  );
  const hadDetails = Boolean(root.querySelector("details[data-phase]"));

  let html = "";

  for (const phase of SECURITY_HARDENING_PHASES) {
    const phaseDone = phase.items.filter((t) => doneMap.get(t.taskKey)).length;
    const openAttr = !hadDetails || openIds.has(phase.id) ? " open" : "";
    html += `<details class="sh-section"${openAttr} data-phase="${escapeHtml(phase.id)}">`;
    html += `<summary><h2>${escapeHtml(phase.label)} `;
    html += `<span class="sh-risk ${escapeHtml(phase.riskClass)}">${escapeHtml(phase.risk)}</span> `;
    html += `<span style="color:#888;font-weight:400;font-size:13px">(${phaseDone}/${phase.items.length})</span></h2></summary>`;
    if (phase.lead) {
      html += `<p class="sh-note" style="margin-top:10px;">${escapeHtml(phase.lead)}</p>`;
    }
    html += `<ul class="sh-list">`;
    for (const item of phase.items) {
      const done = Boolean(doneMap.get(item.taskKey));
      if (hideDone && done) continue;
      html += `<li class="sh-item${done ? " done" : ""}">`;
      html += `<input type="checkbox" data-task="${escapeHtml(item.taskKey)}"${done ? " checked" : ""}>`;
      html += `<div class="sh-body">`;
      html += `<div class="sh-label">${escapeHtml(item.label)}</div>`;
      if (item.note) {
        html += `<div class="sh-note">${escapeHtml(item.note)}</div>`;
      }
      if (item.href) {
        html += `<div class="sh-meta"><a href="${escapeHtml(item.href)}">${escapeHtml(
          item.hrefLabel || item.href
        )}</a></div>`;
      }
      html += `</div></li>`;
    }
    html += `</ul></details>`;
  }

  root.innerHTML = html;
  updateSummary();

  root.querySelectorAll('input[type="checkbox"][data-task]').forEach((input) => {
    input.addEventListener("change", () => {
      setTaskDone(input.dataset.task, input.checked);
    });
  });
}
