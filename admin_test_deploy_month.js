import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const GPSL_MONTHS = [
  { value: "august", label: "August" },
  { value: "september", label: "September" },
  { value: "october", label: "October" },
  { value: "november", label: "November" },
  { value: "december", label: "December" },
  { value: "january", label: "January" },
  { value: "february", label: "February" },
  { value: "march", label: "March" },
  { value: "april", label: "April" },
  { value: "may", label: "May" },
];

function populateMonthSelect() {
  const sel = document.getElementById("monthSelect");
  if (!sel) return;
  sel.innerHTML = GPSL_MONTHS.map(
    (m) => `<option value="${m.value}">${m.label}</option>`
  ).join("");
}

function renderPreview(data) {
  const summary = document.getElementById("previewSummary");
  const table = document.getElementById("previewTable");
  const body = document.getElementById("previewBody");
  const hint = document.getElementById("phraseHint");
  if (!summary || !table || !body) return;

  if (hint && data?.confirm_phrase) {
    hint.textContent = data.confirm_phrase;
  }

  const fixtures = data?.fixtures || [];
  summary.hidden = false;
  summary.innerHTML = `
    <span>Month: <b>${data?.gpsl_month_label || data?.gpsl_month || "—"}</b></span>
    <span>Ready league: <b>${data?.scheduled_league_ready ?? 0}</b></span>
    <span>Blocked / other: <b>${data?.blocked_or_other ?? 0}</b></span>
  `;

  if (!fixtures.length) {
    table.hidden = true;
    body.innerHTML = "";
    return;
  }

  body.innerHTML = fixtures
    .map((f) => {
      const ready = !!f.ready;
      const squads = `${f.home_squad_size ?? "?"} / ${f.away_squad_size ?? "?"}`;
      return `<tr class="${ready ? "" : "not-ready"}">
        <td>${f.matchday ?? "—"}</td>
        <td>${f.division ?? "—"}</td>
        <td>${f.home_club} vs ${f.away_club}</td>
        <td>${f.status} · ${f.competition_type || "league"}</td>
        <td>${squads}</td>
        <td class="${ready ? "ready-yes" : "ready-no"}">${ready ? "Yes" : "No"}</td>
      </tr>`;
    })
    .join("");
  table.hidden = false;
}

async function runPreview() {
  const month = document.getElementById("monthSelect")?.value;
  if (!month) {
    setStatus("previewStatus", "Select a month.", false);
    return;
  }

  setStatus("previewStatus", "Loading preview…");
  const { data, error } = await supabase.rpc("admin_testing_deploy_month_preview", {
    p_gpsl_month: month,
  });

  if (error) {
    setStatus("previewStatus", error.message, false);
    return;
  }

  renderPreview(data);
  setStatus(
    "previewStatus",
    `${data?.scheduled_league_ready ?? 0} league fixture(s) ready to deploy.`,
    true
  );
}

async function runDeploy() {
  const month = document.getElementById("monthSelect")?.value;
  const phrase = document.getElementById("confirmInput")?.value?.trim() || "";
  const expected = document.getElementById("phraseHint")?.textContent?.trim() || "DEPLOY TEST MONTH";

  if (!month) {
    setStatus("deployStatus", "Select a month.", false);
    return;
  }
  if (phrase !== expected) {
    setStatus("deployStatus", `Type exactly: ${expected}`, false);
    return;
  }

  const label =
    GPSL_MONTHS.find((m) => m.value === month)?.label || month;
  if (
    !confirm(
      `Deploy random results for all ready league fixtures in ${label}? This cannot be undone easily.`
    )
  ) {
    return;
  }

  setStatus("deployStatus", "Deploying…");
  const { data, error } = await supabase.rpc("admin_testing_deploy_month_results", {
    p_gpsl_month: month,
    p_confirm_phrase: phrase,
  });

  if (error) {
    setStatus("deployStatus", error.message, false);
    return;
  }

  const errs = data?.errors || [];
  let msg = `Deployed ${data?.deployed_count ?? 0} fixture(s) for ${data?.gpsl_month_label || month}.`;
  if (errs.length) {
    msg += ` ${errs.length} error(s) — see console.`;
    console.warn("deploy month errors:", errs);
  }
  setStatus("deployStatus", msg, errs.length === 0);
  await runPreview();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  populateMonthSelect();
  setStatus("previewStatus", "Select a month and preview.");

  document.getElementById("previewBtn")?.addEventListener("click", runPreview);
  document.getElementById("deployBtn")?.addEventListener("click", runDeploy);
});
