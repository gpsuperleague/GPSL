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
  const nationHint = nation
    ? `Player Nation = club Nation (${nation})`
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
      note: "This is the only maximum",
      count: c.total,
      ok: c.squadSizeOk,
      status: c.squadSizeOk
        ? "Within limit"
        : `${c.squadOver} over limit — release or sell`,
    },
  ];
}
