import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const GPSL_MONTHS = [
  { value: "june", label: "June" },
  { value: "july", label: "July" },
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
  { value: "playoffs", label: "Playoffs" },
];

function populateMonthSelect() {
  const sel = document.getElementById("monthSelect");
  if (!sel) return;
  sel.innerHTML = GPSL_MONTHS.map(
    (m) => `<option value="${m.value}">${m.label}</option>`
  ).join("");
}

/** Clear playoff names when preview RPC has no competition_label yet. */
function fixtureTypeLabel(f) {
  if (f?.competition_label) return f.competition_label;
  const code = String(f?.cup_code || "").toLowerCase();
  const round = Number(f?.cup_round);
  const match = Number(f?.cup_match);
  if (code.startsWith("po_")) {
    if (code === "po_sl_1617") {
      return "Super League Relegation Playoff Final — 16th vs 17th";
    }
    if (code === "po_ch_sb_a") {
      return "Championship A Shield Playoff Final — 16th vs 17th";
    }
    if (code === "po_ch_sb_b") {
      return "Championship B Shield Playoff Final — 16th vs 17th";
    }
    if (code === "po_ch_final") {
      return "Championship Playoff Final — A final winner vs B final winner";
    }
    if (code === "po_sl_final") {
      return "Super League Playoff Final — relegation winner vs Championship Playoff Final winner";
    }
    if (code === "po_ch_a") {
      if (round === 1 && match === 1) return "Championship A Semi Final — 3rd vs 6th";
      if (round === 1 && match === 2) return "Championship A Semi Final — 4th vs 5th";
      if (round === 2) return "Championship A Final — semi-final winners";
      return "Championship A promotion playoff";
    }
    if (code === "po_ch_b") {
      if (round === 1 && match === 1) return "Championship B Semi Final — 3rd vs 6th";
      if (round === 1 && match === 2) return "Championship B Semi Final — 4th vs 5th";
      if (round === 2) return "Championship B Final — semi-final winners";
      return "Championship B promotion playoff";
    }
    return "Playoff";
  }
  if (f?.competition_type === "cup") {
    return `${f.cup_code || "cup"} R${f.cup_round ?? "?"}${
      f.cup_match != null ? ` M${f.cup_match}` : ""
    }`;
  }
  return f?.competition_type || "league";
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
  const intlFixtures = data?.international_fixtures || [];
  const under11 = data?.clubs_under_11 || [];
  const intlReady = data?.international_ready ?? 0;
  const intlBlocked = data?.international_blocked ?? 0;
  summary.hidden = false;
  summary.innerHTML = `
    <span>Month: <b>${data?.gpsl_month_label || data?.gpsl_month || "—"}</b></span>
    <span>Ready league: <b>${data?.scheduled_league_ready ?? 0}</b></span>
    <span>Ready cup: <b>${data?.scheduled_cup_ready ?? 0}</b></span>
    <span>Ready club total: <b>${data?.scheduled_total_ready ?? data?.scheduled_league_ready ?? 0}</b></span>
    <span>Ready internationals: <b>${intlReady}</b></span>
    <span>Blocked intl: <b>${intlBlocked}</b></span>
    <span>Blocked / other club: <b>${data?.blocked_or_other ?? 0}</b></span>
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

  const clubRows = fixtures.map((f) => {
    const ready = !!f.ready;
    const typeLabel = fixtureTypeLabel(f);
    const squads = `${f.home_squad_size ?? "?"} / ${f.away_squad_size ?? "?"}`;
    return `<tr class="${ready ? "" : "not-ready"}">
      <td>${escapeHtml(typeLabel)}</td>
      <td>${f.matchday ?? "—"}</td>
      <td>${f.division ?? "—"}</td>
      <td>${escapeHtml(`${f.home_club || "—"} vs ${f.away_club || "—"}`)}</td>
      <td>${escapeHtml(`${f.status || "scheduled"} · ${f.competition_type || "league"}`)}</td>
      <td>${squads}</td>
      <td class="${ready ? "ready-yes" : "ready-no"}">${ready ? "Yes" : "No"}</td>
      <td>${escapeHtml(f.block_reason || "")}</td>
    </tr>`;
  });

  const intlRows = intlFixtures.map((f) => {
    const ready = !!f.ready;
    return `<tr class="${ready ? "" : "not-ready"}">
      <td>International · ${escapeHtml(f.phase || "—")}</td>
      <td>${f.match_no ?? "—"}</td>
      <td>—</td>
      <td>${escapeHtml(`${f.home_nation || "TBD"} vs ${f.away_nation || "TBD"}`)}</td>
      <td>international</td>
      <td>—</td>
      <td class="${ready ? "ready-yes" : "ready-no"}">${ready ? "Yes" : "No"}</td>
      <td>${escapeHtml(f.block_reason || "")}</td>
    </tr>`;
  });

  const allRows = [...clubRows, ...intlRows];
  if (!allRows.length) {
    table.hidden = true;
    body.innerHTML = "";
    return;
  }

  table.hidden = false;
  body.innerHTML = allRows.join("");
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
  const [clubRes, intlRes] = await Promise.all([
    supabase.rpc("admin_testing_deploy_month_preview", { p_gpsl_month: month }),
    supabase.rpc("admin_testing_deploy_month_international_preview", {
      p_gpsl_month: month,
    }),
  ]);

  if (clubRes.error) {
    setStatus("previewStatus", clubRes.error.message, false);
    return;
  }

  const data = { ...(clubRes.data || {}) };
  if (intlRes.error) {
    data.international_ready = 0;
    data.international_blocked = 0;
    data.international_fixtures = [];
    data.international_preview_error = intlRes.error.message;
  } else {
    data.international_ready = intlRes.data?.international_ready ?? 0;
    data.international_blocked = intlRes.data?.international_blocked ?? 0;
    data.international_fixtures = intlRes.data?.fixtures || [];
  }

  renderPreview(data);
  const clubReady = data?.scheduled_total_ready ?? data?.scheduled_league_ready ?? 0;
  const intlReady = data?.international_ready ?? 0;
  let msg =
    `${clubReady} club fixture(s) ready` +
    ` (${data?.scheduled_league_ready ?? 0} league, ${data?.scheduled_cup_ready ?? 0} cup)` +
    ` · ${intlReady} international(s) ready.`;
  if (data.international_preview_error) {
    msg += ` (Intl preview needs patch: ${data.international_preview_error})`;
  }
  setStatus("previewStatus", msg, true);
}

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
      `Deploy results for ${label}?\n\n• Club league/cup (random scores)\n• Internationals tagged ${label} (auto scores)\n\nThis cannot be undone easily.`
    )
  ) {
    return;
  }

  // One fixture per RPC — larger batches time out and roll back the whole call
  const BATCH_SIZE = 1;
  const MAX_CALLS = 400;
  const MAX_TIMEOUT_RETRIES = 4;
  let totalDeployed = 0;
  let totalLeague = 0;
  let totalCup = 0;
  let totalErrors = 0;
  const errorSummary = {};
  let lastDiscipline = null;
  let afterFixtureId = null;
  let calls = 0;
  let idleRounds = 0;
  let timeoutRetries = 0;

  while (calls < MAX_CALLS) {
    calls += 1;
    setStatus(
      "deployStatus",
      `Deploying ${label}… ${totalDeployed} done` +
        (afterFixtureId ? `, after #${afterFixtureId}` : "") +
        (timeoutRetries ? ` (timeout retry ${timeoutRetries})` : "")
    );

    const { data, error } = await supabase.rpc("admin_testing_deploy_month_results", {
      p_gpsl_month: month,
      p_confirm_phrase: afterFixtureId ? null : phrase,
      p_limit: BATCH_SIZE,
      p_after_fixture_id: afterFixtureId,
      p_include_details: false,
    });

    if (error) {
      const errText = [error.code, error.message, error.details, error.hint]
        .filter(Boolean)
        .join(" — ");
      const timedOut = /statement timeout|canceling statement|Timed out|57014|502|504|upstream/i.test(
        errText || ""
      );
      const needsPatch =
        /p_limit|admin_testing_deploy_month_results|seed_month_discipline|Could not find the function|PGRST202|PGRST203|42883/i.test(
          errText || ""
        );

      if (timedOut && timeoutRetries < MAX_TIMEOUT_RETRIES) {
        timeoutRetries += 1;
        setStatus(
          "deployStatus",
          `Timed out — retrying in 2s (${timeoutRetries}/${MAX_TIMEOUT_RETRIES}). ` +
            `If this keeps happening, re-run fix_list_expiring_and_deploy_month_500.sql in Supabase.`
        );
        await sleep(2000);
        continue;
      }

      console.error("admin_testing_deploy_month_results failed:", error);
      setStatus(
        "deployStatus",
        timedOut
          ? "❌ Timed out repeatedly — re-run supabase/sql/patches/fix_list_expiring_and_deploy_month_500.sql in Supabase SQL Editor, then: SELECT public.admin_diagnose_month_deploy_rpcs('december');"
          : needsPatch
            ? `❌ RPC missing/ambiguous — re-run fix_list_expiring_and_deploy_month_500.sql then hard-refresh.\n${errText}`
            : `❌ ${errText || "Deploy failed (HTTP 500) — re-run fix_list_expiring_and_deploy_month_500.sql"}`,
        false
      );
      await runPreview();
      return;
    }

    // Patched RPC returns {ok:false,error} instead of raising HTTP 500
    if (data && data.ok === false) {
      console.error("admin_testing_deploy_month_results soft-fail:", data);
      setStatus(
        "deployStatus",
        `❌ ${data.error || "Deploy failed"}${data.sqlstate ? ` (${data.sqlstate})` : ""}`,
        false
      );
      await runPreview();
      return;
    }

    timeoutRetries = 0;

    const deployed = data?.deployed_count ?? 0;
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

    if (data?.next_after_fixture_id) {
      afterFixtureId = data.next_after_fixture_id;
    }

    if (deployed === 0 && !data?.has_more) {
      idleRounds += 1;
    } else {
      idleRounds = 0;
    }

    // Finished this cursor sweep
    if (!data?.has_more) {
      const { data: preview } = await supabase.rpc("admin_testing_deploy_month_preview", {
        p_gpsl_month: month,
      });
      const remaining = preview?.scheduled_total_ready ?? 0;
      if (remaining <= 0) break;

      // Restart from top for any fixtures we skipped past (errors / blocked)
      if (idleRounds >= 2) {
        const errLines = Object.entries(errorSummary).map(
          ([text, cnt]) => `${cnt}× ${text}`
        );
        const errHint = errLines.length
          ? ` Errors: ${errLines.join(" | ")}`
          : " Check preview Block reason / squad availability.";
        setStatus(
          "deployStatus",
          `Stopped: ${remaining} fixture(s) still ready but none deployed.${errHint}`,
          false
        );
        await runPreview();
        return;
      }
      afterFixtureId = null;
      continue;
    }

    // Advance even on error for that fixture so we don't spin forever
    if (deployed === 0 && data?.next_after_fixture_id) {
      afterFixtureId = data.next_after_fixture_id;
    }
  }

  // Internationals for this GPSL month (June/July WC etc.)
  let totalIntl = 0;
  let intlAfterId = null;
  let intlCalls = 0;
  let intlIdle = 0;
  while (intlCalls < MAX_CALLS) {
    intlCalls += 1;
    setStatus(
      "deployStatus",
      `Deploying ${label} internationals… ${totalIntl} done` +
        (totalDeployed ? ` (clubs ${totalDeployed})` : "")
    );

    const { data: intlData, error: intlErr } = await supabase.rpc(
      "admin_testing_deploy_month_internationals",
      {
        p_gpsl_month: month,
        p_confirm_phrase: intlAfterId ? null : phrase,
        p_limit: 10,
        p_after_fixture_id: intlAfterId,
      }
    );

    if (intlErr) {
      const errText = [intlErr.code, intlErr.message, intlErr.details, intlErr.hint]
        .filter(Boolean)
        .join(" — ");
      if (/Could not find the function|PGRST202|42883/i.test(errText)) {
        setStatus(
          "deployStatus",
          `Clubs done (${totalDeployed}). Internationals skipped — run admin_testing_deploy_month_internationals_20260901.sql.\n${errText}`,
          totalDeployed > 0
        );
        await runPreview();
        return;
      }
      totalErrors += 1;
      errorSummary[errText || "intl deploy error"] =
        (errorSummary[errText || "intl deploy error"] || 0) + 1;
      break;
    }

    if (intlData && intlData.ok === false) {
      totalErrors += 1;
      errorSummary[intlData.error || "intl deploy failed"] =
        (errorSummary[intlData.error || "intl deploy failed"] || 0) + 1;
      break;
    }

    const intlDeployed = intlData?.deployed_count ?? 0;
    totalIntl += intlDeployed;
    totalErrors += intlData?.error_count ?? 0;
    if (intlData?.next_after_fixture_id) {
      intlAfterId = intlData.next_after_fixture_id;
    }
    if (intlDeployed === 0 && !intlData?.has_more) {
      intlIdle += 1;
      if (intlIdle >= 2) break;
      intlAfterId = null;
      continue;
    }
    if (!intlData?.has_more) break;
  }

  let msg =
    `Deployed ${totalDeployed} club fixture(s) for ${label} (${totalLeague} league, ${totalCup} cup)` +
    ` · ${totalIntl} international(s).`;
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
