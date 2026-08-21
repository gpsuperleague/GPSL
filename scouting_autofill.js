/**
 * Scouting tactic-board autofill: formation quotas (2n+1), budget, registration
 * mins, and position fallbacks when the shortlist is thin at a role.
 */

import {
  MIN_GOALKEEPERS,
  MIN_HOME_GROWN,
  MIN_UNDER_21,
  MIN_SQUAD_SIZE,
  SQUAD_SIZE,
  isHomeGrownPlayer,
  isUnder21,
  isGoalkeeper,
} from "./squad_rules.js";
import { playerEligibleStar } from "./squad_designations.js";

const MAX_PITCH = 11;

const SLOT_IDS = [
  "GK",
  "LB",
  "CB1",
  "CB2",
  "RB",
  "LMF",
  "CMF",
  "RMF",
  "LWF",
  "CF",
  "RWF",
];

/** Preferred → fallbacks when primary position is scarce. */
export const POSITION_FALLBACKS = {
  GK: [],
  LB: ["CB"],
  RB: ["CB"],
  CB: ["LB", "RB", "DMF"],
  DMF: ["CMF"],
  CMF: ["DMF", "AMF"],
  LMF: ["LB", "LWF"],
  RMF: ["RB", "RWF"],
  AMF: ["CMF", "SS"],
  LWF: ["LMF", "SS"],
  RWF: ["RMF", "SS"],
  SS: ["CF", "AMF", "LWF", "RWF"],
  CF: ["SS", "RWF", "LWF"],
  LWB: ["LB", "CB"],
  RWB: ["RB", "CB"],
};

function playerKey(p) {
  return String(p?.Konami_ID ?? p?.player_id ?? "");
}

function clonePlayer(p) {
  return { ...p };
}

export function normalizePlayerPosition(pos) {
  const p = String(pos || "")
    .trim()
    .toUpperCase();
  if (p === "LW") return "LWF";
  if (p === "RW") return "RWF";
  return p;
}

function roleChain(role) {
  const r = normalizePlayerPosition(role);
  const fb = POSITION_FALLBACKS[r] || [];
  return [r, ...fb.map(normalizePlayerPosition)];
}

function marketValue(p) {
  const n = Number(p?.market_value);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function ratingOf(p) {
  return Number(p?.Rating) || 0;
}

function formatMv(n) {
  const v = Number(n) || 0;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}m`;
  if (v >= 1_000) return `${Math.round(v / 1_000)}k`;
  return String(Math.round(v));
}

/**
 * Count formation pitch labels → squad quotas.
 * Outfield: 2×count + 1. GK: 2×count (always 2 for one GK).
 * Trim/pad to maxSquad while keeping at least the XI counts.
 */
export function formationPositionQuotas(slotLabels, maxSquad = SQUAD_SIZE) {
  const pitchCounts = new Map();
  for (const slotId of SLOT_IDS) {
    const label = normalizePlayerPosition(slotLabels?.[slotId] || slotId);
    pitchCounts.set(label, (pitchCounts.get(label) || 0) + 1);
  }

  const quotas = new Map();
  let total = 0;
  for (const [pos, n] of pitchCounts) {
    const q = pos === "GK" ? Math.max(2, 2 * n) : 2 * n + 1;
    quotas.set(pos, q);
    total += q;
  }

  const minKeep = new Map(pitchCounts);
  while (total > maxSquad) {
    let best = null;
    let bestSurplus = 0;
    for (const [pos, q] of quotas) {
      const keep = minKeep.get(pos) || 0;
      const surplus = q - keep;
      if (surplus > bestSurplus) {
        bestSurplus = surplus;
        best = pos;
      }
    }
    if (!best || bestSurplus <= 0) break;
    quotas.set(best, quotas.get(best) - 1);
    total -= 1;
  }

  while (total < maxSquad) {
    let best = null;
    let bestQ = -1;
    for (const [pos, q] of quotas) {
      if (q > bestQ) {
        bestQ = q;
        best = pos;
      }
    }
    if (!best) break;
    quotas.set(best, quotas.get(best) + 1);
    total += 1;
  }

  return { quotas, pitchCounts };
}

function emptyPitchMap() {
  return new Map(SLOT_IDS.map((id) => [id, null]));
}

function needBoost(p, counts, opts) {
  let boost = 0;
  if (counts.gk < opts.minGk && isGoalkeeper(p)) boost += 80;
  if (counts.hg < opts.minHg && isHomeGrownPlayer(p, opts.planNation))
    boost += 50;
  if (counts.u21 < opts.minU21 && isUnder21(p)) boost += 40;
  if (
    counts.stars < opts.minStars &&
    playerEligibleStar(p, opts.minStarRating)
  ) {
    boost += 35;
  }
  return boost;
}

function wouldBreakStarCap(p, counts, opts) {
  if (!playerEligibleStar(p, opts.minStarRating)) return false;
  return counts.stars >= opts.starCap;
}

function pickBest(candidates, used, spent, opts, counts) {
  let best = null;
  let bestScore = -Infinity;
  for (const p of candidates) {
    const id = playerKey(p);
    if (!id || used.has(id)) continue;
    const mv = marketValue(p);
    if (opts.budget != null && spent + mv > opts.budget) continue;
    if (wouldBreakStarCap(p, counts, opts)) continue;

    const score =
      ratingOf(p) * 10 +
      needBoost(p, counts, opts) -
      mv / 1_000_000 +
      (isHomeGrownPlayer(p, opts.planNation) ? 2 : 0) +
      (isUnder21(p) ? 1 : 0);
    if (score > bestScore) {
      bestScore = score;
      best = p;
    }
  }
  return best;
}

function playersMatchingRoles(pool, roles) {
  const want = new Set(roles.map(normalizePlayerPosition));
  return pool.filter((p) => want.has(normalizePlayerPosition(p.Position)));
}

function notePick(counts, p, opts, delta = 1) {
  if (isGoalkeeper(p)) counts.gk += delta;
  if (isHomeGrownPlayer(p, opts.planNation)) counts.hg += delta;
  if (isUnder21(p)) counts.u21 += delta;
  if (playerEligibleStar(p, opts.minStarRating)) counts.stars += delta;
}

function boardSpent(pitch, bench) {
  let s = 0;
  for (const p of pitch.values()) if (p) s += marketValue(p);
  for (const p of bench) if (p) s += marketValue(p);
  return s;
}

function repairRegistrationGaps({ pitch, bench, pool, used, counts, opts }) {
  const boardList = () => {
    const out = [];
    for (const [slotId, p] of pitch.entries()) {
      if (p) out.push({ area: "pitch", slotId, p });
    }
    for (let i = 0; i < bench.length; i++) {
      if (bench[i]) out.push({ area: "bench", index: i, p: bench[i] });
    }
    return out;
  };

  const trySwapIn = (satisfied, candidateFilter) => {
    if (satisfied(counts)) return;
    const candidates = pool
      .filter((p) => !used.has(playerKey(p)) && candidateFilter(p))
      .sort((a, b) => ratingOf(b) - ratingOf(a));

    for (const cand of candidates) {
      const mvCand = marketValue(cand);
      const victims = boardList()
        .filter(({ p }) => !candidateFilter(p))
        .sort((a, b) => ratingOf(a.p) - ratingOf(b.p));

      for (const v of victims) {
        const mvV = marketValue(v.p);
        const nextSpent = boardSpent(pitch, bench) - mvV + mvCand;
        if (opts.budget != null && nextSpent > opts.budget) continue;

        const nextStars =
          counts.stars -
          (playerEligibleStar(v.p, opts.minStarRating) ? 1 : 0) +
          (playerEligibleStar(cand, opts.minStarRating) ? 1 : 0);
        if (nextStars > opts.starCap) continue;

        used.delete(playerKey(v.p));
        used.add(playerKey(cand));
        notePick(counts, v.p, opts, -1);
        notePick(counts, cand, opts, 1);

        if (v.area === "pitch") pitch.set(v.slotId, clonePlayer(cand));
        else bench[v.index] = clonePlayer(cand);
        return;
      }
    }
  };

  trySwapIn((c) => c.gk >= opts.minGk, (p) => isGoalkeeper(p));
  trySwapIn(
    (c) => c.hg >= opts.minHg,
    (p) => isHomeGrownPlayer(p, opts.planNation)
  );
  trySwapIn((c) => c.u21 >= opts.minU21, (p) => isUnder21(p));
  trySwapIn(
    (c) => c.stars >= opts.minStars,
    (p) => playerEligibleStar(p, opts.minStarRating)
  );
}

/**
 * @returns {{ state: object, summary: string, quotas: Map<string,number>, pitchCounts: Map<string,number> }}
 */
export function autoFillScoutingBoard({
  allPlayers,
  slotLabels,
  maxBench = 17,
  maxSquad = SQUAD_SIZE,
  budget = null,
  planNation = null,
  minGk = MIN_GOALKEEPERS,
  minHg = MIN_HOME_GROWN,
  minU21 = MIN_UNDER_21,
  minStars = 0,
  minSquad = MIN_SQUAD_SIZE,
  starCap = 3,
  minStarRating = 79,
}) {
  const benchSize = Math.max(1, Number(maxBench) || 17);
  const squadCap = Math.min(
    Math.max(MAX_PITCH, Number(maxSquad) || SQUAD_SIZE),
    MAX_PITCH + benchSize
  );
  const opts = {
    budget: budget == null || !(Number(budget) > 0) ? null : Number(budget),
    planNation,
    minGk: Number(minGk) || MIN_GOALKEEPERS,
    minHg: Number(minHg) || MIN_HOME_GROWN,
    minU21: Number(minU21) || MIN_UNDER_21,
    minStars: Math.max(0, Number(minStars) || 0),
    minSquad: Number(minSquad) || MIN_SQUAD_SIZE,
    starCap: Math.max(0, Number(starCap) || 0),
    minStarRating: Number(minStarRating) || 79,
  };

  const { quotas, pitchCounts } = formationPositionQuotas(slotLabels, squadCap);
  const pool = [...(allPlayers || [])];
  const used = new Set();
  let spent = 0;
  const counts = { gk: 0, hg: 0, u21: 0, stars: 0 };
  const filledByRole = new Map([...quotas.keys()].map((k) => [k, 0]));

  const pitch = emptyPitchMap();
  const bench = Array(benchSize).fill(null);

  function take(p, roleKey) {
    if (!p) return false;
    const id = playerKey(p);
    if (used.has(id)) return false;
    used.add(id);
    spent += marketValue(p);
    notePick(counts, p, opts);
    if (roleKey) {
      filledByRole.set(roleKey, (filledByRole.get(roleKey) || 0) + 1);
    }
    return true;
  }

  // Pitch: stated position first, then fallbacks
  for (const slotId of SLOT_IDS) {
    const label = normalizePlayerPosition(slotLabels?.[slotId] || slotId);
    const chain = roleChain(label);
    let picked = null;
    for (let depth = 0; depth < chain.length && !picked; depth++) {
      picked = pickBest(
        playersMatchingRoles(pool, [chain[depth]]),
        used,
        spent,
        opts,
        counts
      );
    }
    if (!picked) {
      picked = pickBest(pool, used, spent, opts, counts);
    }
    if (picked && take(picked, label)) {
      pitch.set(slotId, clonePlayer(picked));
    }
  }

  const roleOrder = [...quotas.entries()].sort((a, b) => {
    const needA = a[1] - (filledByRole.get(a[0]) || 0);
    const needB = b[1] - (filledByRole.get(b[0]) || 0);
    return needB - needA;
  });

  function remainingNeed(role) {
    return (quotas.get(role) || 0) - (filledByRole.get(role) || 0);
  }

  let benchIdx = 0;
  while (benchIdx < benchSize && used.size < squadCap) {
    let progress = false;
    for (const [role] of roleOrder) {
      if (benchIdx >= benchSize || used.size >= squadCap) break;
      if (remainingNeed(role) <= 0) continue;
      const chain = roleChain(role);
      let picked = null;
      for (let depth = 0; depth < chain.length && !picked; depth++) {
        picked = pickBest(
          playersMatchingRoles(pool, [chain[depth]]),
          used,
          spent,
          opts,
          counts
        );
      }
      if (picked && take(picked, role)) {
        bench[benchIdx++] = clonePlayer(picked);
        progress = true;
      }
    }
    if (!progress) break;
  }

  while (benchIdx < benchSize && used.size < Math.max(opts.minSquad, squadCap)) {
    if (used.size >= squadCap) break;
    const picked = pickBest(pool, used, spent, opts, counts);
    if (!picked) break;
    let assignRole = normalizePlayerPosition(picked.Position);
    let worstNeed = remainingNeed(assignRole);
    for (const [role] of quotas) {
      const n = remainingNeed(role);
      if (n > worstNeed) {
        worstNeed = n;
        assignRole = role;
      }
    }
    if (!take(picked, assignRole)) break;
    bench[benchIdx++] = clonePlayer(picked);
  }

  repairRegistrationGaps({ pitch, bench, pool, used, counts, opts });
  spent = boardSpent(pitch, bench);

  const leftover = [];
  for (const p of pool) {
    if (!used.has(playerKey(p))) leftover.push(clonePlayer(p));
  }

  const state = {
    pitch,
    bench,
    pool: leftover,
    maxBench: benchSize,
    maxSquad: squadCap,
  };

  const quotaTxt = [...quotas.entries()]
    .map(([pos, q]) => `${pos} ${filledByRole.get(pos) || 0}/${q}`)
    .join(" · ");
  const summary =
    `Filled ${used.size}/${squadCap}` +
    (opts.budget != null
      ? ` · spent ₿${formatMv(spent)} / ₿${formatMv(opts.budget)}`
      : ` · MV ₿${formatMv(spent)}`) +
    ` · GK ${counts.gk}/${opts.minGk} · HG ${counts.hg}/${opts.minHg} · U21 ${counts.u21}/${opts.minU21} · ★ ${counts.stars}` +
    (opts.minStars ? ` (min ${opts.minStars})` : "") +
    ` · ${quotaTxt}`;

  return { state, summary, quotas, pitchCounts };
}
