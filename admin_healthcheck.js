import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js?v=20261108-admin-pins";

primeAdminPageChrome();

const FIRE_LABEL = {
  ok: "Last call",
  not_due: "Not due",
  no_log: "No log",
  miss: "Missed",
};

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function firePassed(state) {
  return state === "ok" || state === "not_due";
}

function renderBoard(payload) {
  const board = document.getElementById("healthBoard");
  const summary = document.getElementById("healthSummary");
  const context = document.getElementById("healthContext");
  const checks = Array.isArray(payload?.checks) ? payload.checks : [];
  const counts = { green: 0, amber: 0, red: 0 };

  const seasonBits = [];
  if (payload?.season_label) seasonBits.push(payload.season_label);
  if (payload?.season_status) seasonBits.push(payload.season_status);
  if (payload?.due_month) seasonBits.push(`last month due: ${payload.due_month}`);
  else seasonBits.push("no month has locked yet");
  if (context) context.textContent = seasonBits.join(" · ");

  let html = "";
  let group = "";
  for (const row of checks) {
    const tone = row?.tone === "green" || row?.tone === "amber" || row?.tone === "red" ? row.tone : "red";
    counts[tone] += 1;
    if (row.group !== group) {
      group = row.group || "Other";
      html += `<h3 class="admin-subheading">${escapeHtml(group)}</h3>`;
    }
    const wiredOn = row.wired === true;
    const firedOn = firePassed(row.fire_state);
    const fireLabel = FIRE_LABEL[row.fire_state] || "Missed";
    html += `<div class="health-item">
      <div class="health-pill tone-${tone}" role="status" aria-label="${escapeHtml(row.label)} ${tone}">
        <span>${escapeHtml(row.label)}</span>
        <span class="health-facts">
          <span class="${wiredOn ? "" : "fact-off"}">${wiredOn ? "Wired" : "Not wired"}</span>
          <span class="${firedOn ? "" : "fact-off"}">${escapeHtml(fireLabel)}</span>
        </span>
      </div>
      <p class="health-detail">${escapeHtml(row.detail)}</p>
    </div>`;
  }

  if (board) board.innerHTML = html || `<p class="note">The read returned no mechanisms.</p>`;
  if (summary) {
    summary.innerHTML = `
      <span class="tone-green">${counts.green} green</span>
      <span class="tone-amber">${counts.amber} amber</span>
      <span class="tone-red">${counts.red} red</span>`;
  }
}

async function runTest() {
  const button = document.getElementById("runTest");
  if (button) {
    button.disabled = true;
    button.textContent = "Reading…";
  }
  setStatus("healthStatus", "Reading schedules and the last stamps…", "warn");
  const { data, error } = await supabase.rpc("admin_mechanism_health");
  if (button) {
    button.disabled = false;
    button.textContent = "Run test";
  }
  if (error) {
    setStatus(
      "healthStatus",
      error.message || "The health read failed. Run supabase/sql/patches/admin_mechanism_health_20261108.sql once.",
      false
    );
    return;
  }
  renderBoard(data || {});
  const when = data?.checked_at ? new Date(data.checked_at).toLocaleString() : "just now";
  setStatus("healthStatus", `Read completed ${when}. Nothing was started.`, true);
}

document.getElementById("runTest")?.addEventListener("click", () => {
  runTest().catch((err) => {
    const button = document.getElementById("runTest");
    if (button) {
      button.disabled = false;
      button.textContent = "Run test";
    }
    setStatus("healthStatus", err?.message || "The health read failed.", false);
  });
});

initAdminPage().catch(() => {
  setStatus("healthStatus", "Admin sign-in failed.", false);
});
