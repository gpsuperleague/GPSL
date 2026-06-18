import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { loadCurrentSeason, CUP_LABELS, loadCupBracket, cupRoundLabel } from "./competition.js";
import { applyCupPageTheme, renderCupHero } from "./trophy_assets.js";

const BALL_COLORS = [
  "#ff9900", "#6cf", "#9df", "#fc9", "#f9a", "#8d8", "#c9f", "#ff6",
];

let isAdmin = false;
let seasonId = null;
let speedMul = 1;
let running = false;
let playerOrder = [];
let byeClubs = [];
let r1Pairings = [];
let r1Byes = [];
let roundCounts = [];
let replayMode = false;

function cupFromUrl() {
  const raw = new URLSearchParams(window.location.search).get("cup");
  if (raw === "spoon") return "bowl";
  return raw || "league_cup";
}

function isReplayMode() {
  return new URLSearchParams(window.location.search).get("replay") === "1";
}

function delay(ms) {
  return new Promise((r) => setTimeout(r, Math.max(40, ms * speedMul)));
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function clubLabel(code) {
  return fullClubName(code) || code;
}

function ballColor(code) {
  let h = 0;
  const s = String(code);
  for (let i = 0; i < s.length; i += 1) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return BALL_COLORS[h % BALL_COLORS.length];
}

function setStatus(msg, kind = "") {
  const el = document.getElementById("drawStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.className = `cup-draw-status${kind ? ` ${kind}` : ""}`;
}

function setAnnounce(phase, headline, sub = "") {
  document.getElementById("announcePhase").textContent = phase;
  document.getElementById("announceHeadline").textContent = headline;
  document.getElementById("announceSub").textContent = sub;
}

function shuffle(arr) {
  const list = [...arr];
  for (let i = list.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [list[i], list[j]] = [list[j], list[i]];
  }
  return list;
}

function layoutBallsInBowl(codes) {
  const pit = document.getElementById("ballPit");
  pit.innerHTML = "";
  const w = pit.clientWidth || 280;
  const h = pit.clientHeight || 200;

  codes.forEach((code, i) => {
    const ball = document.createElement("div");
    ball.className = "cup-draw-ball";
    ball.dataset.code = code;
    ball.style.setProperty("--ball-color", ballColor(code));
    ball.textContent = clubLabel(code);
    const angle = (i / Math.max(codes.length, 1)) * Math.PI * 2 + Math.random() * 0.5;
    const radius = 0.15 + Math.random() * 0.32;
    const left = w / 2 + Math.cos(angle) * w * radius - 26;
    const top = h * 0.35 + Math.sin(angle) * h * radius * 0.55 + Math.random() * 40;
    ball.style.left = `${Math.max(4, Math.min(w - 56, left))}px`;
    ball.style.top = `${Math.max(4, Math.min(h - 56, top))}px`;
    pit.appendChild(ball);
  });
}

async function shakeBowl() {
  const bowl = document.getElementById("bowl");
  const spotlight = document.getElementById("spotlight");
  bowl.classList.remove("shaking");
  void bowl.offsetWidth;
  bowl.classList.add("shaking");
  spotlight.classList.add("on");
  await delay(580);
  spotlight.classList.remove("on");
}

function findBall(code) {
  return document.querySelector(`.cup-draw-ball[data-code="${CSS.escape(code)}"]`);
}

async function pickBall(code) {
  await shakeBowl();
  const ball = findBall(code);
  if (!ball) return;
  ball.classList.add("picked");
  await delay(420);
  ball.classList.add("fly-away");
  ball.style.transform = "translateY(-120px) scale(1.2)";
  await delay(650);
  ball.classList.add("hidden");
}

function appendTie(html) {
  const list = document.getElementById("resultsList");
  list.insertAdjacentHTML("beforeend", html);
  list.scrollTop = list.scrollHeight;
}

function renderRoundStructure(totalTeams, byeCount) {
  const players = totalTeams - byeCount;
  const r1Fixtures = Math.floor(players / 2);
  const cols = [];
  let slots = totalTeams;
  while (slots >= 2) {
    cols.push(slots / 2);
    slots /= 2;
  }

  roundCounts = cols;
  const outline = document.getElementById("bracketOutline");
  const labels = cols.map((n, i) => {
    if (i === 0) return `R1 (${r1Fixtures + byeCount} ties)`;
    return cupRoundLabel(n) || `R${i + 1}`;
  });

  outline.innerHTML = `
    <div class="cup-draw-bracket-outline">
      ${labels
        .map(
          (title, ci) => `
        <div class="cup-draw-bracket-col" data-col="${ci}">
          <div class="col-title">${escapeHtml(title)}</div>
          ${Array.from({ length: cols[ci] }, (_, si) => `<div class="cup-draw-bracket-slot" data-slot="${ci}-${si}">TBD</div>`).join("")}
        </div>`
        )
        .join("")}
    </div>`;
}

function fillBracketSlot(col, slot, label) {
  const el = document.querySelector(
    `.cup-draw-bracket-slot[data-slot="${col}-${slot}"]`
  );
  if (el) {
    el.textContent = label;
    el.classList.add("filled");
  }
}

async function loadDrawContext(cup) {
  const { data, error } = await supabase.rpc("competition_cup_byes_get", {
    p_season_id: seasonId,
    p_cup_code: cup,
  });
  if (error) throw error;

  const qualified = (data?.qualified_clubs || []).map((c) => String(c).toUpperCase());
  byeClubs = (data?.selected_byes || []).map((c) => String(c).toUpperCase());
  const requiredByes = Number(data?.required_byes) || 0;

  if (requiredByes > 0 && byeClubs.length !== requiredByes) {
    throw new Error(
      `Assign exactly ${requiredByes} bye club(s) in GPSL Admin before the draw ceremony.`
    );
  }

  const players = qualified.filter((c) => !byeClubs.includes(c));
  playerOrder = shuffle(players);

  const slots = Number(data?.first_round_slots) || qualified.length;
  renderRoundStructure(slots, byeClubs.length);

  return { qualified, requiredByes, r1Fixtures: Math.floor(players.length / 2) };
}

function buildPairingsFromBracket(nodes) {
  const r1 = nodes.filter((n) => n.round_no === 1).sort((a, b) => a.match_no - b.match_no);
  r1Pairings = [];
  r1Byes = [];

  for (const n of r1) {
    const home = n.home_club_short_name;
    const away = n.away_club_short_name;
    if (home && away) {
      r1Pairings.push({ home, away, matchNo: n.match_no });
    } else if (home && !away) {
      r1Byes.push({ club: home, matchNo: n.match_no });
    }
  }

  const playing = r1Pairings.flatMap((p) => [p.home, p.away]);
  playerOrder = playing.length ? playing : [];
  byeClubs = r1Byes.map((b) => b.club);

  const slots = Math.pow(2, Math.ceil(Math.log2(r1.length * 2)));
  renderRoundStructure(slots, r1Byes.length);
}

async function runCeremony(ctx) {
  running = true;
  document.getElementById("startBtn").disabled = true;
  document.getElementById("resultsList").innerHTML = "";
  r1Pairings = [];
  r1Byes = [];

  let matchNo = 1;
  const byeQueue = [...byeClubs];

  if (byeQueue.length) {
    appendTie(`<div class="cup-draw-round-label">First-round byes</div>`);
    for (let i = 0; i < byeQueue.length; i += 1) {
      const code = byeQueue[i];
      setAnnounce(
        "Bye draw",
        clubLabel(code),
        `Bye to the next round (${i + 1} of ${byeQueue.length})`
      );
      if (!replayMode) await pickBall(code);
      else await delay(350);

      r1Byes.push({ club: code, matchNo });
      appendTie(`
        <div class="cup-draw-tie bye">
          <span class="match-no">M${matchNo}</span>
          <strong>${escapeHtml(clubLabel(code))}</strong>
          <span class="vs">·</span> Bye
        </div>`);
      fillBracketSlot(0, matchNo - 1, `${clubLabel(code)} (bye)`);
      matchNo += 1;
      await delay(300);
    }
  }

  appendTie(`<div class="cup-draw-round-label">Opening round ties</div>`);

  if (replayMode && r1Pairings.length) {
    for (const tie of r1Pairings) {
      setAnnounce(
        "Pairing",
        `${clubLabel(tie.home)} vs ${clubLabel(tie.away)}`,
        `Match ${tie.matchNo}`
      );
      await delay(400);
      appendTie(`
        <div class="cup-draw-tie">
          <span class="match-no">M${tie.matchNo}</span>
          <strong>${escapeHtml(clubLabel(tie.home))}</strong>
          <span class="vs">vs</span>
          <strong>${escapeHtml(clubLabel(tie.away))}</strong>
        </div>`);
      fillBracketSlot(0, tie.matchNo - 1, `${clubLabel(tie.home)} v ${clubLabel(tie.away)}`);
    }
  } else {
    for (let i = 0; i < playerOrder.length; i += 2) {
      const home = playerOrder[i];
      const away = playerOrder[i + 1];
      if (!away) break;

      setAnnounce(
        "Pairing draw",
        `${clubLabel(home)} vs ${clubLabel(away)}`,
        `Opening round tie ${r1Pairings.length + 1} of ${ctx.r1Fixtures}`
      );

      if (!replayMode) {
        await pickBall(home);
        setAnnounce("Pairing draw", clubLabel(away), `Joins ${clubLabel(home)}`);
        await pickBall(away);
      } else {
        await delay(400);
      }

      r1Pairings.push({ home, away, matchNo });
      appendTie(`
        <div class="cup-draw-tie">
          <span class="match-no">M${matchNo}</span>
          <strong>${escapeHtml(clubLabel(home))}</strong>
          <span class="vs">vs</span>
          <strong>${escapeHtml(clubLabel(away))}</strong>
        </div>`);
      fillBracketSlot(0, matchNo - 1, `${clubLabel(home)} v ${clubLabel(away)}`);
      matchNo += 1;
      await delay(280);
    }
  }

  setAnnounce(
    "Draw complete",
    "Opening round set",
    `${r1Pairings.length} ties${r1Byes.length ? ` · ${r1Byes.length} byes` : ""} · ${roundCounts.length} rounds total`
  );

  for (let c = 1; c < roundCounts.length; c += 1) {
    for (let s = 0; s < roundCounts[c]; s += 1) {
      fillBracketSlot(c, s, "Winner TBD");
    }
  }

  running = false;
  document.getElementById("startBtn").disabled = replayMode;

  if (isAdmin && !replayMode) {
    document.getElementById("commitBtn").hidden = false;
    setStatus("Review the draw, then confirm to save the bracket.", "ok");
  } else if (replayMode) {
    setStatus("Replay complete — this bracket is already saved.", "ok");
    document.getElementById("viewBracketBtn").hidden = false;
  }
}

async function commitDraw(cup) {
  setStatus("Saving bracket…");
  document.getElementById("commitBtn").disabled = true;

  const result =
    cup === "league_cup"
      ? await supabase.rpc("competition_draw_league_cup", {
          p_season_id: seasonId,
          p_player_order: playerOrder,
        })
      : await supabase.rpc("competition_draw_prestige_cup", {
          p_season_id: seasonId,
          p_cup_code: cup,
          p_player_order: playerOrder,
        });

  if (result.error) {
    setStatus(result.error.message, "error");
    document.getElementById("commitBtn").disabled = false;
    return;
  }

  setStatus("✅ Bracket saved.", "ok");
  document.getElementById("commitBtn").hidden = true;
  document.getElementById("viewBracketBtn").hidden = false;
  document.getElementById("viewBracketBtn").href = `cups.html?cup=${encodeURIComponent(cup)}`;
}

async function startDraw() {
  if (running) return;
  const cup = document.getElementById("cupSelect").value;

  try {
    setStatus("");
    document.getElementById("commitBtn").hidden = true;
    document.getElementById("viewBracketBtn").hidden = true;

    if (replayMode) {
      const nodes = await loadCupBracket(supabase, cup);
      if (!nodes.length) {
        setStatus("No bracket to replay yet — run the draw first.", "error");
        return;
      }
      buildPairingsFromBracket(nodes);
      layoutBallsInBowl([...new Set([...byeClubs, ...playerOrder])]);
      await runCeremony({ r1Fixtures: r1Pairings.length });
      return;
    }

    if (!isAdmin) {
      setStatus("Only GPSL admins can run a live draw.", "error");
      return;
    }

    const ctx = await loadDrawContext(cup);
    layoutBallsInBowl([...byeClubs, ...playerOrder]);
    setAnnounce("Mixing the bowl", `${ctx.qualified.length} clubs`, CUP_LABELS[cup] || cup);
    await shakeBowl();
    await runCeremony(ctx);
  } catch (err) {
    console.error(err);
    setStatus(err.message || "Draw failed", "error");
    running = false;
    document.getElementById("startBtn").disabled = false;
  }
}

function wireSpeed() {
  document.querySelectorAll(".cup-draw-speed button").forEach((btn) => {
    btn.addEventListener("click", () => {
      speedMul = Number(btn.dataset.speed) || 1;
      document.querySelectorAll(".cup-draw-speed button").forEach((b) => {
        b.classList.toggle("active", b === btn);
      });
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  wireSpeed();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  isAdmin = isGpslAdminUser(user);
  replayMode = isReplayMode();

  const season = await loadCurrentSeason(supabase);
  seasonId = season?.id ?? null;
  if (!seasonId) {
    setStatus("No active season.", "error");
    return;
  }

  const cup = cupFromUrl();
  document.getElementById("cupSelect").value = cup;
  applyCupPageTheme(cup);
  const hero = document.getElementById("cupHero");
  if (hero) hero.innerHTML = renderCupHero(cup, CUP_LABELS[cup]);

  document.getElementById("drawTitle").textContent = replayMode
    ? `${CUP_LABELS[cup] || cup} draw replay`
    : `${CUP_LABELS[cup] || cup} live draw`;

  document.getElementById("drawMeta").textContent = replayMode
    ? "Watch the opening-round pairings revealed again from the saved bracket."
    : isAdmin
      ? "Random draw from the bowl. Byes first, then opening-round pairings. Confirm to save."
      : "Admins run the live draw. You can replay after the bracket exists.";

  if (replayMode) {
    document.getElementById("startBtn").textContent = "Replay draw";
    document.getElementById("commitBtn").hidden = true;
  } else if (!isAdmin) {
    document.getElementById("startBtn").disabled = true;
    setStatus("Live draw is admin-only. Open with ?replay=1 after the bracket is drawn.", "");
  }

  document.getElementById("cupSelect").addEventListener("change", () => {
    const c = document.getElementById("cupSelect").value;
    const u = new URL(window.location.href);
    u.searchParams.set("cup", c);
    if (replayMode) u.searchParams.set("replay", "1");
    history.replaceState(null, "", u);
    applyCupPageTheme(c);
    if (hero) hero.innerHTML = renderCupHero(c, CUP_LABELS[c]);
  });

  document.getElementById("startBtn").addEventListener("click", () => void startDraw());
  document.getElementById("commitBtn").addEventListener("click", () => {
    void commitDraw(document.getElementById("cupSelect").value);
  });
});
