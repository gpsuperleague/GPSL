// Squad composition & home-grown rules (GPSL)

/** Registered squad size (league rule). */
export const SQUAD_SIZE = 28;

export const MIN_HOME_GROWN = 8;

/** Players aged 21 or younger. */
export const MIN_UNDER_21 = 5;

/** Home-grown contract protection: HG + this age or younger. */
export const HG_CONTRACT_MAX_AGE = 23;

export function normalizeNation(value) {
  if (value == null) return "";
  return String(value).trim().toUpperCase();
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
    issues.push(`Squad has ${total} players (max ${SQUAD_SIZE}).`);
  }
  if (homeGrown < MIN_HOME_GROWN) {
    issues.push(
      `Home-grown: ${homeGrown}/${MIN_HOME_GROWN} (player Nation = club Nation).`
    );
  }
  if (under21 < MIN_UNDER_21) {
    issues.push(`Under-21: ${under21}/${MIN_UNDER_21} (age 21 or younger).`);
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
  };
}
