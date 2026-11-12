import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js?v=20261108-admin-pins";

primeAdminPageChrome();

const FIRE_LABEL = {
  ok: "Last call",
  not_due: "Not due",
  no_log: "No log",
  miss: "Missed",
};

/** What each light is looking at. Keyed by the label the health read returns. */
const CHECK_ABOUT = {
  "End of month watcher":
    "The clock that notices a GPSL month has locked and starts the end-of-month jobs. Wired means that job is installed and switched on. Last call means it has run in the last 20 minutes.",
  "End of month jobs":
    "The bundle that runs when a month locks. It looks for a successful stamp for the last GPSL month whose lock time has already passed.",
  "Team of the month":
    "Team of the month for that locked month. It wants a successful stamp for Super League and one for the Championship.",
  "League tables":
    "The league table snapshot saved when that month locked.",
  "GPSL Sport":
    "The GPSL Sport edition generated for that locked month.",
  "TV pick for next month":
    "The TV selections chosen for the following month when this month locked.",
  "International tables":
    "International tables for that month. This is only due while a World Cup cycle is running.",
  "End of season":
    "The admin step that closes a season. It is not on a clock, so it counts as not due while the season is still setup, preseason, or active.",
  "Contract rollover":
    "Contracts moving on when the next season is created. It does not run on a timer, so it stays not due until that season exists.",
  "Half-season contracts":
    "The clock that switches half-season contracts. Wired means the job is installed and on. Last call means it has run in the last 45 minutes.",
  "Transfer engine":
    "The clock that processes bids and listings. In the evening window it uses the one-minute schedule; otherwise the five-minute schedule. Last call means a recent run, or one still in progress.",
  "Bid step hook":
    "The trigger that keeps a new bid on the minimum step. Wired means it is switched on. There is no log of each bid, so last call stays unconfirmed.",
  "Transfer window hook":
    "The trigger that notices the transfer window open or close. Wired means it is switched on. Each firing is not written down.",
  "Transfer inbox hook":
    "The trigger that writes an inbox note when a transfer completes. Wired means it is switched on. Each firing is not written down.",
  "Arrangement fines":
    "No-proposal and late-arrangement fines for the last locked month. It looks for that month’s stamp.",
  "Reply deadline fines":
    "Fines for missing a reply to a proposed kick-off, stamped for the last locked month.",
  "Check-in fines":
    "Fines for missing check-in at an agreed kick-off, stamped for the last locked month.",
  "Black box forfeits":
    "Forfeits for matches left as a manual black box when that month locked.",
  "Early arrangement awards":
    "Rewards for arranging a match early, applied when that month locked.",
  "Check-in notices":
    "The clock that sends check-in notices as kick-off approaches. Last call means it has run in the last 5 minutes.",
  "Vacant club walkovers":
    "The clock that awards a walkover when a club in the fixture is vacant. Last call means it has run in the last 20 minutes.",
  "Commercial income":
    "The clock that posts club commercial income. Last call means it has run in the last 30 minutes.",
  "Injury rolls":
    "Confirming a result is what rolls for a new injury. Wired means that call is still in place. Last call means a roll was recorded in the last 3 days. A quiet spell with no new injury can still be green.",
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

function renderReasons() {
  const board = document.getElementById("healthBoard");
  if (!board) return;
  board.innerHTML = Object.entries(CHECK_ABOUT)
    .map(
      ([label, about]) => `<div class="health-item">
      <div class="health-pill" role="status" aria-label="${escapeHtml(label)}">
        <span>${escapeHtml(label)}</span>
      </div>
      <p class="health-about">${escapeHtml(about)}</p>
    </div>`
    )
    .join("");
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
    const about = CHECK_ABOUT[String(row.label || "").trim()] || "";
    html += `<div class="health-item">
      <div class="health-pill tone-${tone}" role="status" aria-label="${escapeHtml(row.label)} ${tone}">
        <span>${escapeHtml(row.label)}</span>
        <span class="health-facts">
          <span class="${wiredOn ? "" : "fact-off"}">${wiredOn ? "Wired" : "Not wired"}</span>
          <span class="${firedOn ? "" : "fact-off"}">${escapeHtml(fireLabel)}</span>
        </span>
      </div>
      ${about ? `<p class="health-about">${escapeHtml(about)}</p>` : ""}
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
  setStatus("healthStatus", "Reading schedules and the last stamps…", "warn");
  const { data, error } = await supabase.rpc("admin_mechanism_health");
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

renderReasons();
setStatus("healthStatus", "Reading schedules and the last stamps…", "warn");

initAdminPage()
  .then((user) => {
    if (!user) return;
    return runTest();
  })
  .catch((err) => {
    setStatus("healthStatus", err?.message || "Admin sign-in failed.", false);
  });
