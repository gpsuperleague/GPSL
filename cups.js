import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  CUP_CODES,
  CUP_LABELS,
  loadCupBracket,
  loadCupQualified,
  groupCupBracketByRound,
  formatFixtureScore,
} from "./competition.js";

function cupFromUrl() {
  const raw = new URLSearchParams(window.location.search).get("cup");
  if (raw && CUP_CODES.includes(raw)) return raw;
  return null;
}

let myClubShort = null;
let currentCup = "league_cup";

function renderToolbar() {
  const bar = document.getElementById("cupToolbar");
  bar.innerHTML = "";
  for (const code of CUP_CODES) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = CUP_LABELS[code] || code;
    btn.className = currentCup === code ? "active" : "";
    btn.onclick = () => {
      currentCup = code;
      renderToolbar();
      renderCup();
    };
    bar.appendChild(btn);
  }
}

function renderQualified(clubs) {
  const el = document.getElementById("qualifiedList");
  if (!clubs.length) {
    el.innerHTML =
      '<span class="empty">No qualifiers — need standings (prestige) or season clubs (league cup).</span>';
    return;
  }
  el.textContent = clubs
    .map((s) => fullClubName(s) || s)
    .join(" · ");
}

function renderBracket(nodes) {
  const root = document.getElementById("bracketRoot");
  if (!nodes.length) {
    root.innerHTML =
      '<p class="empty">No bracket yet. Admin draws this cup in GPSL Admin.</p>';
    return;
  }

  const rounds = groupCupBracketByRound(nodes);
  root.innerHTML = rounds
    .map(({ round_no, matches }) => {
      const rows = matches
        .map((m) => {
          const home = m.home_club_name || m.home_club_short_name || "TBD";
          const away = m.away_club_name || m.away_club_short_name || "TBD";
          const score =
            m.fixture_status === "played"
              ? formatFixtureScore(m)
              : m.fixture_id
                ? "vs"
                : "—";
          const mine =
            myClubShort &&
            [m.home_club_short_name, m.away_club_short_name].some(
              (c) => (c || "").toUpperCase() === myClubShort.toUpperCase()
            );
          const win =
            m.winner_club_name &&
            `<div style="color:#6f6;font-size:12px;">Winner: ${m.winner_club_name}</div>`;
          return `
            <tr class="${mine ? "my-club" : ""}">
              <td>M${m.match_no}</td>
              <td>${home} ${score} ${away}${win || ""}</td>
            </tr>
          `;
        })
        .join("");

      return `
        <div class="round-block">
          <div class="round-title">Round ${round_no}</div>
          <table class="bracket">
            <thead><tr><th>#</th><th>Match</th></tr></thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      `;
    })
    .join("");
}

async function renderCup() {
  const qualified = await loadCupQualified(supabase, currentCup);
  renderQualified(qualified);
  renderBracket(await loadCupBracket(supabase, currentCup));
}

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

  myClubShort = club?.ShortName ?? null;

  const urlCup = cupFromUrl();
  if (urlCup) currentCup = urlCup;

  document.getElementById("pageMeta").textContent =
    "Prestige cups (table places) and League Cup (60-club knockout)";

  renderToolbar();
  await renderCup();
});
