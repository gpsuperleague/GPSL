// Squad composition & home-grown rules (GPSL)

/** Registered squad size (league rule). */
export const SQUAD_SIZE = 28;

export const SQUAD_OVERFLOW_CONFIRM_MESSAGE =
  "You are at max squad size (28 players).\n\n" +
  "Are you sure?\n\n" +
  "Going over the 28-player limit will automatically release your highest-rated " +
  "player who was not signed this season. If you have foreign club interest remaining, " +
  "that sale will be used; otherwise the player is released for market value.";

/**
 * Call before any action that will sign a player to this club.
 * @returns {Promise<boolean>} false if user cancelled
 */
export async function fetchClubSquadTotal(supabase, clubShort) {
  if (!clubShort || !supabase) return null;

  const { data, error } = await supabase.rpc("check_club_squad_composition", {
    p_club_short_name: clubShort,
  });

  if (error) {
    console.warn("check_club_squad_composition:", error);
    return null;
  }

  return Number(data?.total ?? 0);
}

/** Short warning for bid modals (all listings, GPDB, etc.). */
export function squadOverflowBidWarningText(squadTotal) {
  const n = Number(squadTotal);
  if (!Number.isFinite(n) || n < SQUAD_SIZE) return "";

  if (n === SQUAD_SIZE) {
    return (
      "You are at max squad size (28). If you win this player, going over 28 will " +
      "automatically release your highest-rated player (not signed this season) — " +
      "foreign sale if available, otherwise market value."
    );
  }

  return (
    `You have ${n} players (max ${SQUAD_SIZE}). If you win this player, overflow release ` +
    "will apply again (highest rated not signed this season)."
  );
}

export async function fetchClubSquadComposition(supabase, clubShort) {
  if (!clubShort || !supabase) return null;

  const { data, error } = await supabase.rpc("check_club_squad_composition", {
    p_club_short_name: clubShort,
  });

  if (error) {
    console.warn("check_club_squad_composition:", error);
    return null;
  }

  return {
    total: Number(data?.total ?? 0),
    homeGrown: Number(data?.home_grown ?? 0),
    under21: Number(data?.under_21 ?? 0),
    clubNation: data?.club_nation ?? null,
  };
}

/** Counts if this player is added to the squad (e.g. winning a bid). */
export function projectedSquadCompositionAfterSigning(
  composition,
  player,
  clubNation
) {
  const nation = clubNation ?? composition?.clubNation ?? null;
  let homeGrown = composition?.homeGrown ?? 0;
  let under21 = composition?.under21 ?? 0;
  let total = composition?.total ?? 0;

  if (player) {
    total += 1;
    if (isHomeGrownPlayer(player, nation)) homeGrown += 1;
    if (isUnder21(player)) under21 += 1;
  }

  return {
    total,
    homeGrown,
    under21,
    homeGrownOk: homeGrown >= MIN_HOME_GROWN,
    under21Ok: under21 >= MIN_UNDER_21,
  };
}

/** Lines for bid modal / confirm when HG or U21 minimums would still fail after winning. */
export function squadCompositionBidWarningLines(composition, player, clubNation) {
  if (!composition) return [];

  const proj = projectedSquadCompositionAfterSigning(
    composition,
    player,
    clubNation
  );
  const lines = [];

  if (!proj.homeGrownOk) {
    const helps = player && isHomeGrownPlayer(player, clubNation ?? composition.clubNation);
    const need = MIN_HOME_GROWN - proj.homeGrown;
    lines.push(
      helps
        ? `Home-grown: you have ${composition.homeGrown} (need ${MIN_HOME_GROWN}). If you win, this player counts as home-grown → ${proj.homeGrown} total (still need ${need} more).`
        : `Home-grown: you have ${composition.homeGrown} (need ${MIN_HOME_GROWN}). If you win, you would have ${proj.homeGrown} — still ${need} short.`
    );
  }

  if (!proj.under21Ok) {
    const helps = player && isUnder21(player);
    const need = MIN_UNDER_21 - proj.under21;
    const ageLabel =
      player?.Age != null && String(player.Age).trim() !== ""
        ? ` (age ${player.Age})`
        : "";
    lines.push(
      helps
        ? `Under-21: you have ${composition.under21} (need ${MIN_UNDER_21}). If you win, this player counts${ageLabel} → ${proj.under21} total (still need ${need} more).`
        : `Under-21: you have ${composition.under21} (need ${MIN_UNDER_21}). If you win, you would have ${proj.under21} — still ${need} short.`
    );
  }

  return lines;
}

/** Modal warning block (overflow + HG/U21). */
export async function squadRulesBidWarningLines(
  supabase,
  clubShort,
  clubNation,
  player
) {
  const composition = await fetchClubSquadComposition(supabase, clubShort);
  const lines = [];

  const overflow = squadOverflowBidWarningText(composition?.total);
  if (overflow) lines.push(overflow);

  lines.push(
    ...squadCompositionBidWarningLines(composition, player, clubNation)
  );

  return lines.filter(Boolean);
}

/**
 * Confirm before bid / signing (overflow + HG/U21 warnings — not a hard block).
 * @returns {Promise<boolean>} false if user cancelled
 */
export async function confirmSquadRulesBeforeBid(
  supabase,
  clubShort,
  clubNation,
  player
) {
  const composition = await fetchClubSquadComposition(supabase, clubShort);
  if (!composition) return true;

  const sections = [];

  const total = composition.total;
  if (total >= SQUAD_SIZE) {
    let msg = SQUAD_OVERFLOW_CONFIRM_MESSAGE;
    if (total > SQUAD_SIZE) {
      msg =
        `You have ${total} players (max ${SQUAD_SIZE}).\n\n` +
        "Are you sure?\n\n" +
        "Adding another player will automatically release your highest-rated player " +
        "who was not signed this season. If you have foreign club interest remaining, " +
        "that sale will be used; otherwise the player is released for market value.";
    }
    sections.push(msg);
  }

  const compLines = squadCompositionBidWarningLines(
    composition,
    player,
    clubNation
  );
  if (compLines.length) {
    sections.push(
      "Squad composition (minimum rules):\n\n" +
        compLines.map((l) => `• ${l}`).join("\n\n") +
        "\n\nYou can still place your bid, but your squad must meet home-grown and under-21 minimums."
    );
  }

  if (!sections.length) return true;

  return window.confirm(
    sections.length === 1
      ? sections[0]
      : sections.join("\n\n────────────\n\n")
  );
}

/** @deprecated use confirmSquadRulesBeforeBid */
export async function confirmSquadOverflowBeforeSigning(
  supabase,
  clubShort,
  player = null,
  clubNation = null
) {
  return confirmSquadRulesBeforeBid(supabase, clubShort, clubNation, player);
}

/** Alert after assign if server auto-released a player (overflow). */
export function alertOverflowReleaseFromAssign(assignResult) {
  const rel = assignResult?.overflow_release;
  if (!rel?.released) return;

  const name = rel.player_name || rel.player_id || "A player";
  const rating = rel.rating != null ? ` (rating ${rel.rating})` : "";
  const fee = Number(rel.fee) || 0;
  const feeStr = `₿ ${fee.toLocaleString("en-GB")}`;

  if (rel.method === "foreign" && rel.foreign_buyer_name) {
    window.alert(
      `Squad was over 28 players.\n\n` +
        `${name}${rating} was sold to ${rel.foreign_buyer_name} (${feeStr}, market value).`
    );
    return;
  }

  window.alert(
    `Squad was over 28 players.\n\n` +
      `${name}${rating} was released as a free agent. Your club received ${feeStr} (market value).`
  );
}

export const MIN_HOME_GROWN = 8;

/** Players aged 21 or younger. */
export const MIN_UNDER_21 = 5;

/** Home-grown contract protection: HG + this age or younger. */
export const HG_CONTRACT_MAX_AGE = 23;

/**
 * Compare key for home-grown (Nation match). Handles "United States" vs "UnitedStates".
 */
export function normalizeNation(value) {
  if (value == null) return "";
  return String(value)
    .trim()
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toUpperCase();
}

/** Human-readable nation label for UI (e.g. UnitedStates → United States). */
export function formatNationLabel(value) {
  if (value == null || !String(value).trim()) return "";
  const spaced = String(value)
    .trim()
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return spaced
    .split(" ")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

/** Home-grown = player Nation matches club Nation (Clubs.Nation / Players.Nation). */
export function isHomeGrownPlayer(player, clubNation) {
  const pn = normalizeNation(player?.Nation);
  const cn = normalizeNation(clubNation);
  if (!pn || !cn) return false;
  return pn === cn;
}

export function isUnder21(player) {
  const age = Number(player?.Age);
  return Number.isFinite(age) && age <= 21;
}

/** Inline badges beside player name on Squad (HG, U21, or HG & U21). */
export function playerSquadQualificationBadges(player, clubNation) {
  const hg = isHomeGrownPlayer(player, clubNation);
  const u21 = isUnder21(player);
  if (!hg && !u21) return "";

  const parts = [];
  const titleParts = [];
  if (hg) {
    parts.push("HG");
    titleParts.push("Home-grown (player Nation matches club Nation)");
  }
  if (u21) {
    parts.push("U21");
    titleParts.push("Under-21 (age 21 or younger)");
  }

  const label = parts.join(" & ");
  const title = titleParts.join(" · ");

  return ` <span class="squad-qual-badge" title="${title}">${label}</span>`;
}

export function isHgContractProtected(player, clubNation) {
  const age = Number(player?.Age);
  return (
    isHomeGrownPlayer(player, clubNation) &&
    Number.isFinite(age) &&
    age <= HG_CONTRACT_MAX_AGE
  );
}

/**
 * @param {object[]} players — contracted squad (Players rows)
 * @param {string} clubNation — Clubs.Nation
 */
export function analyseSquadComposition(players, clubNation) {
  const list = players || [];
  const total = list.length;

  let homeGrown = 0;
  let under21 = 0;

  for (const p of list) {
    if (isHomeGrownPlayer(p, clubNation)) homeGrown += 1;
    if (isUnder21(p)) under21 += 1;
  }

  const issues = [];

  if (total > SQUAD_SIZE) {
    issues.push(
      `Squad size: you have ${total} players — maximum is ${SQUAD_SIZE}.`
    );
  }
  if (homeGrown < MIN_HOME_GROWN) {
    issues.push(
      `Home-grown: you have ${homeGrown} — need ${MIN_HOME_GROWN - homeGrown} more with Nation matching your club.`
    );
  }
  if (under21 < MIN_UNDER_21) {
    issues.push(
      `Under-21: you have ${under21} — need ${MIN_UNDER_21 - under21} more aged 21 or younger.`
    );
  }

  return {
    total,
    homeGrown,
    under21,
    squadSize: SQUAD_SIZE,
    minHomeGrown: MIN_HOME_GROWN,
    minUnder21: MIN_UNDER_21,
    compliant: issues.length === 0,
    issues,
    homeGrownOk: homeGrown >= MIN_HOME_GROWN,
    under21Ok: under21 >= MIN_UNDER_21,
    squadSizeOk: total <= SQUAD_SIZE,
    homeGrownShort: Math.max(0, MIN_HOME_GROWN - homeGrown),
    under21Short: Math.max(0, MIN_UNDER_21 - under21),
    squadOver: Math.max(0, total - SQUAD_SIZE),
  };
}

/** Display rows for the Squad page rules panel. */
export function squadComplianceRuleRows(c, clubNation) {
  const nation = clubNation?.trim() || null;
  const nationLabel = nation ? formatNationLabel(nation) : null;
  const nationHint = nationLabel
    ? `Player Nation = club Nation (${nationLabel})`
    : "Player Nation must match club Nation (set on Club Details)";

  return [
    {
      rule: "Home-grown",
      whoCounts: nationHint,
      requirement: `At least ${MIN_HOME_GROWN}`,
      note: "No upper limit",
      count: c.homeGrown,
      ok: c.homeGrownOk,
      status: c.homeGrownOk
        ? "Requirement met"
        : `Need ${c.homeGrownShort} more`,
    },
    {
      rule: "Under-21",
      whoCounts: "Age 21 or younger",
      requirement: `At least ${MIN_UNDER_21}`,
      note: "No upper limit",
      count: c.under21,
      ok: c.under21Ok,
      status: c.under21Ok
        ? "Requirement met"
        : `Need ${c.under21Short} more`,
    },
    {
      rule: "Squad size",
      whoCounts: "All players on your contract list below",
      requirement: `No more than ${SQUAD_SIZE}`,
      note: "Signing a 29th auto-releases highest rated (not signed this season)",
      count: c.total,
      ok: c.squadSizeOk,
      status: c.squadSizeOk
        ? "Within limit"
        : c.total === SQUAD_SIZE
          ? "At max — next signing triggers overflow release"
          : `${c.squadOver} over limit — overflow may apply on next signing`,
    },
  ];
}
