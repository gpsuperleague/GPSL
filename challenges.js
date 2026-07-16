import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

const STAT_LABELS = {
  player_max_goals: "Player max goals",
  player_max_assists: "Player max assists",
  club_wins: "League/cup wins",
  club_goals_for: "Goals scored",
  club_clean_sheets: "Clean sheets",
  club_potm_awards: "POTM awards",
  transfer_sign_nation: "Sign by nationality",
};

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    renderError("No club linked to your account.");
    return;
  }

  document.title = `Season challenges — ${fullClubName(club.ShortName) || club.ShortName}`;

  await Promise.all([
    loadBigPrizePacks(),
    loadMyProgress(club.ShortName),
    loadCatalog(),
    loadAwards(club.ShortName),
  ]);
});

async function loadBigPrizePacks() {
  const el = document.getElementById("challengeBigPrize");
  if (!el) return;

  const { data, error } = await supabase
    .from("competition_challenge_period_packs_public")
    .select("*")
    .order("window_phase");

  if (error) {
    // Fallback to base table if view not deployed yet
    const { data: packs, error: err2 } = await supabase
      .from("competition_challenge_period_pack")
      .select("window_phase, cash_amount, pack");
    if (err2 || !packs?.length) {
      el.innerHTML =
        "Big prize packs not loaded yet — admin must run prize-pack SQL and set packs on Season challenges.";
      return;
    }
    el.innerHTML = packs
      .map((p) => {
        const label = p.window_phase === "mid" ? "Mid (Jan–May)" : "Start (Jun–Dec)";
        const pack = p.pack || {};
        const med = (pack.medical_tokens || []).map((n) => `${n}-match`).join(", ") || "—";
        const disc = (pack.fee_discounts || []).map((n) => `${n}%`).join(", ") || "—";
        const appeals = pack.appeal_cards ?? 0;
        return `<div style="margin-bottom:10px;"><b>${label}</b><br>
          Cash ${formatMoney(Number(p.cash_amount || 0))} · Medical: ${med} ·
          Transfer discounts: ${disc} · Appeal cards: ${appeals}</div>`;
      })
      .join("");
    return;
  }

  if (!data?.length) {
    el.innerHTML = "No big prize packs configured yet.";
    return;
  }

  el.innerHTML = data
    .map((p) => {
      const label = p.window_phase === "mid" ? "Mid (Jan–May)" : "Start (Jun–Dec)";
      return `<div style="margin-bottom:10px;"><b>${label}</b><br>${p.pack_summary || "—"}</div>`;
    })
    .join("");
}

function renderError(msg) {
  document.getElementById("challengeProgressGrid").innerHTML =
    `<p class="meta">${msg}</p>`;
  document.getElementById("challengeCatalogGrid").innerHTML = "";
  document.getElementById("challengeAwardsList").innerHTML = "";
}

function progressLabel(c) {
  if (c.awarded) return { text: "Awarded", className: "challenge-status-awarded" };
  if (c.expired) return { text: "Window closed", className: "challenge-status-expired" };
  return {
    text: `${c.current_value ?? 0} / ${c.target_value}`,
    className: "",
  };
}

function renderProgressGrid(items, elId, emptyMsg) {
  const grid = document.getElementById(elId);
  if (!grid) return;

  if (!items?.length) {
    grid.innerHTML = `<p class="meta">${emptyMsg}</p>`;
    return;
  }

  grid.innerHTML = items
    .map((c) => {
      const st = progressLabel(c);
      return `
        <div class="challenge-card">
          <span class="window-tag">${c.window_phase || "—"}</span>
          <h3>${c.title}</h3>
          <p class="challenge-progress ${st.className}">${st.text}</p>
          <p class="challenge-meta">
            ${STAT_LABELS[c.stat_type] || c.stat_type}${
              c.stat_param ? ` (${c.stat_param})` : ""
            } · Prize ${formatMoney(Number(c.prize_amount || 0))}
          </p>
        </div>
      `;
    })
    .join("");
}

async function loadMyProgress(clubShortName) {
  const grid = document.getElementById("challengeProgressGrid");
  const { data, error } = await supabase.rpc("competition_challenge_club_progress", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("competition_challenge") || msg.includes("function")) {
      grid.innerHTML =
        '<p class="meta">Challenges not enabled yet — admin must run <code>competition_challenges.sql</code> and seed targets.</p>';
      return;
    }
    grid.innerHTML = `<p class="meta">❌ ${msg}</p>`;
    return;
  }

  const items = (data?.challenges || []).map((c) => ({
    ...c,
    title: c.title,
  }));

  if (!items.length) {
    grid.innerHTML =
      '<p class="meta">No active challenges this season. Ask admin to seed targets on <b>Admin → Season challenges</b>.</p>';
    return;
  }

  renderProgressGrid(items, "challengeProgressGrid", "No challenges.");
}

async function loadCatalog() {
  const { data, error } = await supabase
    .from("competition_challenges_public")
    .select("*")
    .order("window_phase")
    .order("sort_order");

  if (error) {
    document.getElementById("challengeCatalogGrid").innerHTML =
      `<p class="meta">Could not load challenge list (${error.message}).</p>`;
    return;
  }

  if (!data?.length) {
    document.getElementById("challengeCatalogGrid").innerHTML =
      '<p class="meta">No challenges configured for the current season.</p>';
    return;
  }

  document.getElementById("challengeCatalogGrid").innerHTML = data
    .map(
      (c) => `
      <div class="challenge-card">
        <span class="window-tag">${c.window_phase}</span>
        <h3>${c.title}</h3>
        <p class="challenge-meta">
          ${c.gpsl_month_from_label}–${c.gpsl_month_to_label}<br>
          ${STAT_LABELS[c.stat_type] || c.stat_type}${
            c.stat_param ? ` (${c.stat_param})` : ""
          } ≥ <b>${c.target_value}</b><br>
          Prize ${formatMoney(Number(c.prize_amount || 0))}
        </p>
      </div>
    `
    )
    .join("");
}

async function loadAwards(clubShortName) {
  const list = document.getElementById("challengeAwardsList");
  const { data, error } = await supabase
    .from("competition_challenge_awards_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .order("awarded_at", { ascending: false });

  if (error) {
    list.innerHTML = `<li class="meta">Could not load awards.</li>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = "<li class=\"meta\">No challenge prizes awarded yet.</li>";
    return;
  }

  list.innerHTML = data
    .map(
      (a) =>
        `<li><b>${a.challenge_title}</b> — ${formatMoney(a.amount)} (${a.stat_value}/${a.target_value}) · ${new Date(a.awarded_at).toLocaleDateString("en-GB")}</li>`
    )
    .join("");
}
