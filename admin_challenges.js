import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney, loadCurrentSeason } from "./competition.js";

primeAdminPageChrome();

const STAT_LABELS = {
  player_max_goals: "Player max goals",
  player_max_assists: "Player max assists",
  club_wins: "Club wins",
  club_goals_for: "Club goals",
  club_clean_sheets: "Clean sheets",
  club_potm_awards: "POTM awards",
  transfer_sign_nation: "Sign by nationality",
};

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const season = await loadCurrentSeason(supabase);
  currentSeasonId = season?.id ?? null;

  document.getElementById("challengeWindow").onchange = syncWindowMonths;
  document.getElementById("challengeStatType").onchange = syncStatParamVisibility;
  document.getElementById("saveChallengeDefaultsBtn").onclick = saveChallengeDefaults;
  document.getElementById("saveChallengePacksBtn").onclick = saveChallengePacks;
  document.getElementById("seedChallengesBtn").onclick = seedChallenges;
  document.getElementById("recheckChallengesBtn").onclick = recheckChallenges;
  document.getElementById("refreshProgressBoardBtn").onclick = loadChallengeProgressBoard;
  document.getElementById("saveChallengeBtn").onclick = saveChallenge;
  document.getElementById("clearChallengeFormBtn").onclick = clearChallengeForm;
  document.getElementById("saveChallengeTemplateBtn").onclick = saveChallengeTemplate;

  syncWindowMonths();
  syncStatParamVisibility();
  await loadChallengeDefaults();
  await loadChallengePacks();
  await loadChallengeList();
  await loadChallengeTemplates();
  await loadChallengeProgressBoard();
  await loadChallengeAwards();
});

function parseIntList(raw, allowed) {
  return String(raw || "")
    .split(/[,;\s]+/)
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isFinite(n) && n > 0 && (!allowed || allowed.includes(n)));
}

function fillPackFields(phase, row) {
  const pack = row?.pack || {};
  const prefix = phase === "start" ? "packStart" : "packMid";
  const nameEl = document.getElementById(`${prefix}Name`);
  if (nameEl) {
    nameEl.value =
      row?.pack_name ||
      (phase === "start" ? "Start of Season Challenge Prize" : "Mid-Season Challenge Prize");
  }
  document.getElementById(`${prefix}Cash`).value = row?.cash_amount ?? 0;
  document.getElementById(`${prefix}Medical`).value = (pack.medical_tokens || []).join(",");
  document.getElementById(`${prefix}Discount`).value = (pack.fee_discounts || []).join(",");
  document.getElementById(`${prefix}Appeals`).value = pack.appeal_cards ?? 0;
  const draftEl = document.getElementById(`${prefix}Draft`);
  if (draftEl) draftEl.value = pack.draft_tokens ?? 0;
}

async function loadChallengePacks() {
  const { data, error } = await supabase
    .from("competition_challenge_period_pack")
    .select("*");
  if (error) {
    setStatus("challengePacksStatus", "❌ " + error.message + " — run prize packs SQL", false);
    return;
  }
  for (const row of data || []) {
    if (row.window_phase === "start" || row.window_phase === "mid") {
      fillPackFields(row.window_phase, row);
    }
  }
}

function packPayload(phase) {
  const prefix = phase === "start" ? "packStart" : "packMid";
  return {
    window_phase: phase,
    pack_name: (document.getElementById(`${prefix}Name`)?.value || "").trim() || null,
    cash_amount: Number(document.getElementById(`${prefix}Cash`).value) || 0,
    pack: {
      medical_tokens: parseIntList(document.getElementById(`${prefix}Medical`).value, [2, 4, 6, 8, 10]),
      fee_discounts: parseIntList(document.getElementById(`${prefix}Discount`).value).filter((n) => n <= 50),
      appeal_cards: Math.max(0, Number(document.getElementById(`${prefix}Appeals`).value) || 0),
      draft_tokens: Math.max(0, Number(document.getElementById(`${prefix}Draft`)?.value) || 0),
    },
  };
}

async function saveChallengePacks() {
  setStatus("challengePacksStatus", "Saving packs…");
  const { error } = await supabase.rpc("admin_update_challenge_period_packs", {
    p_packs: [packPayload("start"), packPayload("mid")],
  });
  if (error) {
    setStatus("challengePacksStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "challengePacksStatus",
    "✅ Big prize packs saved — first club to finish all challenges in a window gets this automatically.",
    true
  );
}

function syncWindowMonths() {
  const window = document.getElementById("challengeWindow").value;
  const from = document.getElementById("challengeMonthFrom");
  const to = document.getElementById("challengeMonthTo");
  if (window === "start") {
    from.value = "june";
    to.value = "december";
  } else {
    from.value = "january";
    to.value = "may";
  }
}

function syncStatParamVisibility() {
  const stat = document.getElementById("challengeStatType").value;
  const wrap = document.getElementById("challengeStatParamWrap");
  if (!wrap) return;
  wrap.hidden = stat !== "transfer_sign_nation";
  if (stat === "transfer_sign_nation") {
    const target = document.getElementById("challengeTarget");
    if (target && !target.value) target.value = "1";
  }
}

async function loadChallengeDefaults() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error) {
    setStatus("challengeDefaultsStatus", "❌ " + error.message, false);
    return;
  }
  document.getElementById("challengeDefaultPrize").value = data.challenge_default_prize ?? 1000000;
  document.getElementById("challengePeriodBonus").value = data.challenge_period_bonus ?? 5000000;
  const prizeEl = document.getElementById("challengePrize");
  if (prizeEl && !prizeEl.value) {
    prizeEl.value = String(data.challenge_default_prize ?? 1000000);
  }
}

async function saveChallengeDefaults() {
  setStatus("challengeDefaultsStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_challenge_settings", {
    p_settings: {
      challenge_default_prize: Number(document.getElementById("challengeDefaultPrize").value),
      challenge_period_bonus: Number(document.getElementById("challengePeriodBonus").value),
    },
  });
  if (error) {
    setStatus("challengeDefaultsStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("challengeDefaultsStatus", "✅ Defaults saved.", true);
}

function clearChallengeForm() {
  document.getElementById("challengeEditId").value = "";
  document.getElementById("challengeTitle").value = "";
  document.getElementById("challengeTarget").value = "";
  document.getElementById("challengeStatParam").value = "";
  document.getElementById("challengeWindow").value = "start";
  syncWindowMonths();
  document.getElementById("challengeStatType").value = "club_wins";
  syncStatParamVisibility();
  document.getElementById("challengeIncludeLeague").checked = true;
  document.getElementById("challengeIncludeCup").checked = false;
  document.getElementById("challengeActive").checked = true;
  loadChallengeDefaults();
  setStatus("challengeFormStatus", "");
}

function fillChallengeForm(row) {
  document.getElementById("challengeEditId").value = String(row.id);
  document.getElementById("challengeTitle").value = row.title || "";
  document.getElementById("challengeWindow").value = row.window_phase || "start";
  document.getElementById("challengeMonthFrom").value = row.gpsl_month_from;
  document.getElementById("challengeMonthTo").value = row.gpsl_month_to;
  document.getElementById("challengeStatType").value = row.stat_type;
  document.getElementById("challengeStatParam").value = row.stat_param || "";
  document.getElementById("challengeTarget").value = String(row.target_value);
  document.getElementById("challengePrize").value = String(row.prize_amount);
  document.getElementById("challengeIncludeLeague").checked = row.include_league !== false;
  document.getElementById("challengeIncludeCup").checked = !!row.include_cup;
  document.getElementById("challengeActive").checked = row.is_active !== false;
  syncStatParamVisibility();
}

async function loadChallengeList() {
  const list = document.getElementById("challengeList");
  if (!list) return;

  if (!currentSeasonId) {
    list.innerHTML = "<p class='note'>No current season.</p>";
    return;
  }

  const { data, error } = await supabase
    .from("competition_challenges_public")
    .select("*")
    .eq("season_id", currentSeasonId)
    .order("window_phase")
    .order("sort_order");

  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message} — run competition_challenges.sql</p>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = "<p class='note'>No challenges yet. Seed defaults or add one above.</p>";
    return;
  }

  const start = data.filter((r) => r.window_phase === "start");
  const mid = data.filter((r) => r.window_phase === "mid");

  function renderRow(row) {
    const comps = [row.include_league && "league", row.include_cup && "cup"].filter(Boolean).join("+");
    const nation =
      row.stat_type === "transfer_sign_nation" && row.stat_param
        ? ` (${row.stat_param})`
        : "";
    return `
      <div class="challenge-admin-item">
        <div>
          <b>${row.title}</b>
          <span class="challenge-admin-meta">
            ${row.gpsl_month_from_label}–${row.gpsl_month_to_label}
            · ${STAT_LABELS[row.stat_type] || row.stat_type}${nation} ≥ ${row.target_value}
            · ${formatMoney(row.prize_amount)} · ${comps || "—"}
            ${row.is_active ? "" : " · <i>inactive</i>"}
          </span>
        </div>
        <div class="challenge-admin-actions">
          <button type="button" class="button challenge-edit-btn" data-id="${row.id}">Edit</button>
          <button type="button" class="button challenge-del-btn" data-id="${row.id}">Delete</button>
        </div>
      </div>
    `;
  }

  function renderGroup(label, rows) {
    if (!rows.length) {
      return `<h3 style="margin:14px 0 8px;color:#ccc;font-size:14px;">${label}</h3>
        <p class="note">No targets in this window.</p>`;
    }
    return `<h3 style="margin:14px 0 8px;color:#ccc;font-size:14px;">${label}</h3>
      ${rows.map(renderRow).join("")}`;
  }

  list.innerHTML =
    renderGroup("Start of season", start) + renderGroup("Mid-season", mid);

  list.querySelectorAll(".challenge-edit-btn").forEach((btn) => {
    btn.onclick = () => {
      const row = data.find((r) => String(r.id) === btn.dataset.id);
      if (row) fillChallengeForm(row);
    };
  });

  list.querySelectorAll(".challenge-del-btn").forEach((btn) => {
    btn.onclick = async () => {
      if (!confirm("Delete this challenge?")) return;
      const { error: delErr } = await supabase.rpc("competition_admin_delete_challenge", {
        p_challenge_id: Number(btn.dataset.id),
      });
      if (delErr) {
        setStatus("challengeListStatus", "❌ " + delErr.message, false);
        return;
      }
      await loadChallengeList();
      setStatus("challengeListStatus", "Challenge deleted.", true);
    };
  });
}

async function loadChallengeProgressBoard() {
  const board = document.getElementById("challengeProgressBoard");
  if (!board) return;

  board.innerHTML = "<p class='note'>Loading progress…</p>";
  const { data, error } = await supabase.rpc("competition_admin_challenge_progress_board", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    board.innerHTML = `<p class="note">❌ ${error.message} — run competition_challenges_admin_recheck_board.sql</p>`;
    return;
  }

  const challenges = data?.challenges || [];
  const bigPrizes = data?.big_prizes || data?.period_bonuses || [];
  const winnersEl = document.getElementById("challengeBigPrizeWinners");

  if (winnersEl) {
    if (!bigPrizes.length) {
      winnersEl.innerHTML =
        "<p class='note'>No big-prize status yet — run competition_challenge_pack_names.sql then refresh.</p>";
    } else {
      winnersEl.innerHTML = bigPrizes
        .map((b) => {
          const name = b.pack_name || (b.window_phase === "mid" ? "Mid-Season Challenge Prize" : "Start of Season Challenge Prize");
          if (b.claimed || b.club_short_name) {
            const when = b.awarded_at
              ? new Date(b.awarded_at).toLocaleString("en-GB")
              : "";
            return `<div class="challenge-admin-item" style="display:block;">
              <b>${name}</b>
              <div class="note" style="margin:6px 0 0;color:#8d8;">
                Won by <b>${b.club_name || b.club_short_name}</b>
                ${b.amount != null ? ` · ${formatMoney(b.amount)}` : ""}
                ${when ? ` · ${when}` : ""}
              </div>
              ${b.pack_summary ? `<div class="note" style="margin-top:4px;">${b.pack_summary}</div>` : ""}
            </div>`;
          }
          return `<div class="challenge-admin-item" style="display:block;">
            <b>${name}</b>
            <div class="note" style="margin:6px 0 0;color:#fc6;">Still available — nobody has finished all ${b.window_phase} challenges yet.</div>
            ${b.pack_summary ? `<div class="note" style="margin-top:4px;">${b.pack_summary}</div>` : ""}
          </div>`;
        })
        .join("");
    }
  }

  if (!challenges.length) {
    board.innerHTML = "<p class='note'>No active challenges to score.</p>";
    return;
  }

  board.innerHTML = challenges
    .map((c) => {
      const achievers = c.achievers || [];
      const list =
        achievers.length === 0
          ? `<div class="note" style="margin:6px 0 0;">Nobody has met this yet.</div>`
          : `<ul style="margin:8px 0 0;padding-left:18px;font-size:13px;line-height:1.5;">
              ${achievers
                .map((a) => {
                  const badge = a.awarded
                    ? `<span style="color:#8d8;">Paid</span>`
                    : `<span style="color:#fc6;">Met — unpaid</span>`;
                  return `<li><b>${a.club_name || a.club_short_name}</b> — ${a.current_value}/${a.target_value} · ${badge}</li>`;
                })
                .join("")}
            </ul>`;
      const openTag = c.window_open
        ? `<span style="color:#8d8;">window open</span>`
        : `<span style="color:#a88;">window closed</span>`;
      return `
        <div class="challenge-admin-item" style="display:block;">
          <div>
            <b>${c.title}</b>
            <span class="challenge-admin-meta">
              ${c.window_phase} · ${STAT_LABELS[c.stat_type] || c.stat_type}${
                c.stat_param ? ` (${c.stat_param})` : ""
              } ≥ ${c.target_value} · ${formatMoney(c.prize_amount)} · ${openTag}
              · ${c.achiever_count || 0} club(s)
            </span>
          </div>
          ${list}
        </div>`;
    })
    .join("");
}

async function loadChallengeAwards() {
  const list = document.getElementById("challengeAwardsList");
  if (!list || !currentSeasonId) return;

  const { data, error } = await supabase
    .from("competition_challenge_awards_public")
    .select("*")
    .eq("season_id", currentSeasonId)
    .order("awarded_at", { ascending: false });

  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message}</p>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = "<p class='note'>No awards yet.</p>";
    return;
  }

  list.innerHTML = data
    .map(
      (a) =>
        `<div class="challenge-admin-item">
          <span><b>${a.club_name || a.club_short_name}</b> — ${a.challenge_title}
          (${a.stat_value}/${a.target_value}) · ${formatMoney(a.amount)}</span>
        </div>`
    )
    .join("");
}

async function saveChallenge() {
  if (!currentSeasonId) {
    setStatus("challengeFormStatus", "No current season.", false);
    return;
  }

  const title = document.getElementById("challengeTitle").value.trim();
  if (!title) {
    setStatus("challengeFormStatus", "Title required.", false);
    return;
  }

  const payload = {
    season_id: currentSeasonId,
    id: document.getElementById("challengeEditId").value || null,
    title,
    window_phase: document.getElementById("challengeWindow").value,
    gpsl_month_from: document.getElementById("challengeMonthFrom").value,
    gpsl_month_to: document.getElementById("challengeMonthTo").value,
    stat_type: document.getElementById("challengeStatType").value,
    stat_param: (document.getElementById("challengeStatParam").value || "").trim().toUpperCase() || null,
    target_value: Number(document.getElementById("challengeTarget").value),
    prize_amount: Number(document.getElementById("challengePrize").value),
    include_league: document.getElementById("challengeIncludeLeague").checked,
    include_cup: document.getElementById("challengeIncludeCup").checked,
    is_active: document.getElementById("challengeActive").checked,
  };

  if (payload.stat_type === "transfer_sign_nation" && !payload.stat_param) {
    setStatus("challengeFormStatus", "Nation code required (e.g. NOR, ESP, TPE).", false);
    return;
  }

  setStatus("challengeFormStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_save_challenge", {
    p_challenge: payload,
  });

  if (error) {
    setStatus("challengeFormStatus", "❌ " + error.message, false);
    return;
  }

  clearChallengeForm();
  await loadChallengeList();
  setStatus("challengeFormStatus", `✅ Saved challenge #${data}.`, true);
}

async function seedChallenges() {
  if (!currentSeasonId) {
    setStatus("challengeListStatus", "No current season.", false);
    return;
  }
  setStatus("challengeListStatus", "Seeding…");
  const { data, error } = await supabase.rpc("competition_admin_seed_challenge_defaults", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("challengeListStatus", "❌ " + error.message, false);
    return;
  }
  await loadChallengeList();
  setStatus("challengeListStatus", `✅ Seeded ${data ?? 0} challenges.`, true);
}

async function loadChallengeTemplates() {
  const list = document.getElementById("challengeTemplateList");
  if (!list) return;

  const { data, error } = await supabase.rpc("competition_admin_list_challenge_templates");
  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message} — run competition_challenge_templates.sql</p>`;
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    list.innerHTML =
      "<p class='note'>No saved templates yet. Add targets above, then Save current targets.</p>";
    return;
  }

  list.innerHTML = rows
    .map((t) => {
      const when = t.updated_at
        ? new Date(t.updated_at).toLocaleDateString("en-GB")
        : "";
      const startN = Number(t.start_count) || 0;
      const midN = Number(t.mid_count) || 0;
      const anyN = Number(t.target_count) || startN + midN;
      return `<div class="challenge-admin-item">
        <div>
          <b>${t.name}</b>
          <span class="challenge-admin-meta">
            ${anyN} targets
            (${startN} start · ${midN} mid)
            ${when ? ` · updated ${when}` : ""}
          </span>
        </div>
        <div class="challenge-admin-actions">
          <button type="button" class="button tpl-apply-btn" data-id="${t.id}" data-phase="start" data-name="${encodeURIComponent(t.name || "")}" ${anyN ? "" : "disabled"}>Apply to Start</button>
          <button type="button" class="button tpl-apply-btn" data-id="${t.id}" data-phase="mid" data-name="${encodeURIComponent(t.name || "")}" ${anyN ? "" : "disabled"}>Apply to Mid</button>
          <button type="button" class="button tpl-delete-btn" data-id="${t.id}">Delete</button>
        </div>
      </div>`;
    })
    .join("");

  list.querySelectorAll(".tpl-apply-btn").forEach((btn) => {
    btn.onclick = () =>
      applyChallengeTemplate(
        Number(btn.dataset.id),
        decodeURIComponent(btn.dataset.name || ""),
        btn.dataset.phase
      );
  });
  list.querySelectorAll(".tpl-delete-btn").forEach((btn) => {
    btn.onclick = () => deleteChallengeTemplate(Number(btn.dataset.id));
  });
}

async function saveChallengeTemplate() {
  const name = (document.getElementById("challengeTemplateName")?.value || "").trim();
  if (!name) {
    setStatus("challengeTemplateStatus", "Enter a template name.", false);
    return;
  }
  setStatus("challengeTemplateStatus", "Saving template…");
  const { data, error } = await supabase.rpc("competition_admin_save_challenge_template", {
    p_name: name,
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus(
      "challengeTemplateStatus",
      "❌ " + error.message + " — run competition_challenge_templates.sql",
      false
    );
    return;
  }
  document.getElementById("challengeTemplateName").value = "";
  await loadChallengeTemplates();
  setStatus(
    "challengeTemplateStatus",
    `✅ Saved “${data?.name || name}” (${data?.target_count ?? "?"} targets). Survives league reset.`,
    true
  );
}

async function applyChallengeTemplate(templateId, templateName, windowPhase) {
  if (!currentSeasonId) {
    setStatus("challengeTemplateStatus", "No current season.", false);
    return;
  }

  const phaseLabel = windowPhase === "mid" ? "Mid-season" : "Start of season";
  const monthHint =
    windowPhase === "mid" ? "January–May" : "August–December";
  if (
    !confirm(
      `Apply “${templateName || templateId}” → ${phaseLabel}?\n\n` +
        `• Uses that window’s targets if present, otherwise copies the other window across\n` +
        `• Months reset to ${monthHint} (edit afterwards)\n` +
        `• Replaces existing ${phaseLabel.toLowerCase()} targets only`
    )
  ) {
    return;
  }

  setStatus("challengeTemplateStatus", `Applying ${phaseLabel} targets…`);
  const { data, error } = await supabase.rpc("competition_admin_apply_challenge_template", {
    p_template_id: templateId,
    p_season_id: currentSeasonId,
    p_replace: true,
    p_window_phase: windowPhase,
  });
  if (error) {
    setStatus(
      "challengeTemplateStatus",
      "❌ " + error.message + " — re-run competition_challenge_templates.sql",
      false
    );
    return;
  }
  await loadChallengeList();
  await loadChallengeProgressBoard();
  const remapNote = data?.remapped
    ? ` (copied from the other window; months set to ${monthHint})`
    : ` (months set to ${monthHint})`;
  setStatus(
    "challengeTemplateStatus",
    `✅ Applied ${data?.inserted ?? 0} ${phaseLabel.toLowerCase()} target(s)${remapNote}. Edit them in the Targets list.`,
    true
  );
}

async function deleteChallengeTemplate(templateId) {
  if (!confirm("Delete this saved template? This cannot be undone.")) return;
  setStatus("challengeTemplateStatus", "Deleting…");
  const { error } = await supabase.rpc("competition_admin_delete_challenge_template", {
    p_template_id: templateId,
  });
  if (error) {
    setStatus("challengeTemplateStatus", "❌ " + error.message, false);
    return;
  }
  await loadChallengeTemplates();
  setStatus("challengeTemplateStatus", "✅ Template deleted.", true);
}

async function recheckChallenges() {
  setStatus("challengeListStatus", "Rechecking all clubs (catch-up payout)…");
  const { data, error } = await supabase.rpc("competition_admin_recheck_challenges", {
    p_season_id: currentSeasonId,
    p_ignore_window: true,
  });
  if (error) {
    setStatus(
      "challengeListStatus",
      "❌ " + error.message + " — run competition_challenges_admin_recheck_board.sql",
      false
    );
    return;
  }
  await loadChallengeProgressBoard();
  await loadChallengeAwards();
  setStatus(
    "challengeListStatus",
    `✅ Awarded ${data?.challenges_awarded ?? 0} new challenge prize(s). Progress board refreshed.`,
    true
  );
}
