/**
 * GPSL international nation flag images (images/flags/{CODE}.png).
 * Slugs match flagcdn.com (ISO 3166-1 alpha-2 or UK subdivisions).
 */

/** @type {Record<string, string>} */
export const FLAGCDN_SLUG_BY_CODE = {
  ARG: "ar",
  FRA: "fr",
  BRA: "br",
  ENG: "gb-eng",
  BEL: "be",
  POR: "pt",
  NED: "nl",
  ESP: "es",
  ITA: "it",
  CRO: "hr",
  URU: "uy",
  MAR: "ma",
  COL: "co",
  GER: "de",
  MEX: "mx",
  USA: "us",
  SUI: "ch",
  JPN: "jp",
  SEN: "sn",
  IRN: "ir",
  DEN: "dk",
  KOR: "kr",
  AUS: "au",
  UKR: "ua",
  TUR: "tr",
  ECU: "ec",
  POL: "pl",
  SRB: "rs",
  WAL: "gb-wls",
  CAN: "ca",
  GHA: "gh",
  NOR: "no",
  PAR: "py",
  CRC: "cr",
  EGY: "eg",
  ALG: "dz",
  SCO: "gb-sct",
  AUT: "at",
  HUN: "hu",
  CZE: "cz",
  NGA: "ng",
  PAN: "pa",
  TUN: "tn",
  PER: "pe",
  CHI: "cl",
  ROU: "ro",
  SVK: "sk",
  SWE: "se",
  FIN: "fi",
  IRL: "ie",
  CMR: "cm",
  RSA: "za",
  JAM: "jm",
  BOL: "bo",
  VEN: "ve",
  IRQ: "iq",
  QAT: "qa",
  KSA: "sa",
  NZL: "nz",
  CHN: "cn",
};

export function nationFlagCode(nationOrCode) {
  if (!nationOrCode) return null;
  if (typeof nationOrCode === "string") return nationOrCode.trim().toUpperCase() || null;
  const code = nationOrCode.code ?? nationOrCode.nation_code;
  return code ? String(code).trim().toUpperCase() : null;
}

export function nationFlagSrc(nationOrCode) {
  const code = nationFlagCode(nationOrCode);
  if (!code || !FLAGCDN_SLUG_BY_CODE[code]) return null;
  return `images/flags/${code}.png`;
}

export function renderNationFlag(nation, size = "lg") {
  const code = nationFlagCode(nation);
  const emoji =
    (typeof nation === "object" && nation?.flag_emoji) || "🏳️";
  const sizeCls = size === "sm" ? "nat-flag-sm" : "nat-flag-lg";
  const src = nationFlagSrc(code);

  if (src) {
    const alt = typeof nation === "object" && nation?.name ? nation.name : code || "Nation";
    return (
      `<img class="nat-flag-img ${sizeCls}" src="${src}" alt="${escapeAttr(alt)} flag" loading="lazy" ` +
      `onerror="this.style.display='none';this.nextElementSibling?.classList.remove('nat-flag-fallback-hidden');" />` +
      `<span class="nat-flag nat-flag-fallback ${sizeCls} nat-flag-fallback-hidden" aria-hidden="true">${emoji}</span>`
    );
  }

  return `<span class="nat-flag ${sizeCls}" aria-hidden="true">${emoji}</span>`;
}

function escapeAttr(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}
