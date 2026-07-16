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

  syncWindowMonths();
  syncStatParamVisibility();
  await loadChallengeDefaults();
  await loadChallengePacks();
  await loadChallengeList();
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
    list.innerHTML = "<p class='note'>No challenges yet. Seed defaults or add one below.</p>";
    return;
  }

  list.innerHTML = data
    .map((row) => {
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
              ${row.window_phase} · ${row.gpsl_month_from_label}–${row.gpsl_month_to_label}
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
    })
    .join("");

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
  const bonuses = data?.period_bonuses || [];

  if (!challenges.length) {
    board.innerHTML = "<p class='note'>No active challenges to score.</p>";
    return;
  }

  let html = challenges
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

  if (bonuses.length) {
    html += `<div class="challenge-admin-item" style="display:block;margin-top:12px;">
      <b>Period bonus (first to finish all)</b>
      <ul style="margin:8px 0 0;padding-left:18px;font-size:13px;">
        ${bonuses
          .map(
            (b) =>
              `<li><b>${b.club_name || b.club_short_name}</b> — ${b.window_phase} · ${formatMoney(b.amount)}</li>`
          )
          .join("")}
      </ul>
    </div>`;
  }

  board.innerHTML = html;
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
