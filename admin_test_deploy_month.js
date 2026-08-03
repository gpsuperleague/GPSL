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
      const typeLabel = fixtureTypeLabel(f);
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
      `Deploy random results for all ready league and cup fixtures in ${label}? This cannot be undone easily.`
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
      const timedOut = /statement timeout|canceling statement|Timed out|57014/i.test(
        error.message || ""
      );
      const needsPatch =
        error.message.includes("p_limit") ||
        error.message.includes("admin_testing_deploy_month_results") ||
        error.message.includes("seed_month_discipline");

      if (timedOut && timeoutRetries < MAX_TIMEOUT_RETRIES) {
        timeoutRetries += 1;
        setStatus(
          "deployStatus",
          `Timed out — retrying in 2s (${timeoutRetries}/${MAX_TIMEOUT_RETRIES}). ` +
            `If this keeps happening, run admin_testing_deploy_month_one_at_a_time.sql in Supabase.`
        );
        await sleep(2000);
        continue;
      }

      setStatus(
        "deployStatus",
        timedOut
          ? "❌ Timed out repeatedly — run supabase/sql/patches/admin_testing_deploy_month_one_at_a_time.sql in Supabase, hard-refresh this page, then retry. Already-played fixtures stay deployed."
          : needsPatch
            ? "❌ Run admin_testing_deploy_month_one_at_a_time.sql in Supabase, then retry."
            : error.message,
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
