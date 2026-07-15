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
  const under11Wrap = document.getElementById("under11Wrap");
  const table = document.getElementById("previewTable");
  const body = document.getElementById("previewBody");
  const hint = document.getElementById("phraseHint");
  if (!summary || !table || !body) return;

  if (hint && data?.confirm_phrase) {
    hint.textContent = data.confirm_phrase;
  }

  const fixtures = data?.fixtures || [];
  const under11 = data?.clubs_under_11 || [];
  summary.hidden = false;
  summary.innerHTML = `
    <span>Month: <b>${data?.gpsl_month_label || data?.gpsl_month || "—"}</b></span>
    <span>Ready league: <b>${data?.scheduled_league_ready ?? 0}</b></span>
    <span>Ready cup: <b>${data?.scheduled_cup_ready ?? 0}</b></span>
    <span>Ready total: <b>${data?.scheduled_total_ready ?? data?.scheduled_league_ready ?? 0}</b></span>
    <span>Blocked / other: <b>${data?.blocked_or_other ?? 0}</b></span>
    <span>Owned clubs &lt;11: <b>${under11.length}</b></span>
  `;

  if (under11Wrap) {
    if (under11.length) {
      const sample = under11
        .slice(0, 12)
        .map((c) => `${c.club_short || c.club_name} (${c.squad_size})`)
        .join(", ");
      const more = under11.length > 12 ? ` … +${under11.length - 12} more` : "";
      under11Wrap.hidden = false;
      under11Wrap.innerHTML =
        `<b>Clubs under 11 players</b> (deploy skips these fixtures): ${escapeHtml(sample)}${escapeHtml(more)}`;
    } else {
      under11Wrap.hidden = true;
      under11Wrap.innerHTML = "";
    }
  }

  if (!fixtures.length) {
    table.hidden = true;
    body.innerHTML = "";
    return;
  }

  body.innerHTML = fixtures
    .map((f) => {
      const ready = !!f.ready;
      const typeLabel =
        f.competition_type === "cup"
          ? `${f.cup_code || "cup"} R${f.cup_round ?? "?"}`
          : f.competition_type || "league";
      const squads = `${f.home_squad_size ?? "?"} / ${f.away_squad_size ?? "?"}`;
      return `<tr class="${ready ? "" : "not-ready"}">
        <td>${escapeHtml(typeLabel)}</td>
        <td>${f.matchday ?? "—"}</td>
        <td>${f.division ?? "—"}</td>
        <td>${f.home_club} vs ${f.away_club}</td>
        <td>${f.status} · ${f.competition_type || "league"}</td>
        <td>${squads}</td>
        <td class="${ready ? "ready-yes" : "ready-no"}">${ready ? "Yes" : "No"}</td>
        <td>${escapeHtml(f.block_reason || "")}</td>
      </tr>`;
    })
    .join("");
  table.hidden = false;
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
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
    `${data?.scheduled_total_ready ?? data?.scheduled_league_ready ?? 0} fixture(s) ready to deploy ` +
      `(${data?.scheduled_league_ready ?? 0} league, ${data?.scheduled_cup_ready ?? 0} cup).`,
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
      `Deploy random results for all ready league and cup fixtures in ${label}? This cannot be undone easily.`
    )
  ) {
    return;
  }

  const BATCH_SIZE = 10;
  const MAX_PASSES = 24;
  let totalDeployed = 0;
  let totalLeague = 0;
  let totalCup = 0;
  let totalErrors = 0;
  const errorSummary = {};
  let lastDiscipline = null;
  let pass = 0;

  while (pass < MAX_PASSES) {
    pass += 1;
    let afterFixtureId = null;
    let passDeployed = 0;

    while (true) {
      setStatus(
        "deployStatus",
        `Deploying ${label}… pass ${pass}, batch of ${BATCH_SIZE}${afterFixtureId ? ` (after #${afterFixtureId})` : ""}`
      );

      const { data, error } = await supabase.rpc("admin_testing_deploy_month_results", {
        p_gpsl_month: month,
        p_confirm_phrase: afterFixtureId ? null : phrase,
        p_limit: BATCH_SIZE,
        p_after_fixture_id: afterFixtureId,
        p_include_details: false,
      });

      if (error) {
        const needsPatch =
          error.message.includes("p_limit") ||
          error.message.includes("admin_testing_deploy_month_results") ||
          error.message.includes("seed_month_discipline");
        setStatus(
          "deployStatus",
          needsPatch
            ? "❌ Re-run supabase/sql/patches/admin_testing_deploy_month_discipline.sql in Supabase, then retry."
            : error.message,
          false
        );
        return;
      }

      const deployed = data?.deployed_count ?? 0;
      passDeployed += deployed;
      totalDeployed += deployed;
      totalLeague += data?.league_deployed_count ?? 0;
      totalCup += data?.cup_deployed_count ?? 0;
      totalErrors += data?.error_count ?? 0;
      if (data?.discipline) lastDiscipline = data.discipline;

      for (const [text, cnt] of Object.entries(data?.error_summary || {})) {
        errorSummary[text] = (errorSummary[text] || 0) + cnt;
      }

      if (data?.errors?.length) {
        console.warn("deploy month batch errors:", data.errors);
      }

      if (!data?.has_more) break;
      afterFixtureId = data.next_after_fixture_id;
      if (!afterFixtureId) break;
    }

    const { data: preview } = await supabase.rpc("admin_testing_deploy_month_preview", {
      p_gpsl_month: month,
    });
    const remaining = preview?.scheduled_total_ready ?? 0;

    if (remaining <= 0) break;
    if (passDeployed === 0) {
      const errLines = Object.entries(errorSummary).map(
        ([text, cnt]) => `${cnt}× ${text}`
      );
      const errHint = errLines.length
        ? ` Errors: ${errLines.join(" | ")}`
        : " No RPC errors returned — open browser console for batch details, or re-run preview and check Block reason.";
      setStatus(
        "deployStatus",
        `Stopped: ${remaining} fixture(s) still ready but none deployed this pass.${errHint}`,
        false
      );
      await runPreview();
      return;
    }
  }

  let msg = `Deployed ${totalDeployed} fixture(s) for ${label} (${totalLeague} league, ${totalCup} cup).`;
  if (lastDiscipline?.ok) {
    if (lastDiscipline.skipped) {
      msg += ` Cards already seeded (${lastDiscipline.yellows_existing_before ?? "?"}Y / ${lastDiscipline.reds_existing_before ?? "?"}R).`;
    } else {
      msg += ` Cards: +${lastDiscipline.yellows_added ?? 0} yellow, +${lastDiscipline.reds_added ?? 0} red.`;
    }
  } else if (lastDiscipline?.error) {
    msg += ` Card seeding failed: ${lastDiscipline.error}`;
  }
  if (totalErrors) {
    const lines = Object.entries(errorSummary).map(([text, cnt]) => `${cnt}× ${text}`);
    msg += ` ${totalErrors} error(s): ${lines.join(" | ") || "see console"}`;
  }
  setStatus("deployStatus", msg, totalErrors === 0 && !lastDiscipline?.error);
  await runPreview();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  populateMonthSelect();
  setStatus("previewStatus", "Select a month and preview.");

  document.getElementById("previewBtn")?.addEventListener("click", runPreview);
  document.getElementById("deployBtn")?.addEventListener("click", runDeploy);
});
