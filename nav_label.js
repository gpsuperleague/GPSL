/** Title case for top-nav dropdown labels (and, or, etc. stay lowercase). */

const NAV_SMALL_WORDS = new Set([
  "a",
  "an",
  "the",
  "and",
  "but",
  "or",
  "for",
  "nor",
  "on",
  "at",
  "to",
  "by",
  "in",
  "of",
  "etc",
  "as",
  "per",
  "vs",
  "from",
  "with",
  "into",
]);

function titleCaseToken(token, isEdge) {
  if (token === "&") return "&";

  const match = token.match(/^(\W*)([A-Za-z0-9]+)(\W*)$/);
  if (!match) return token;

  const [, prefix, core, suffix] = match;
  if (/^[A-Z0-9]{2,}$/.test(core)) return token;

  const lower = core.toLowerCase();
  if (!isEdge && NAV_SMALL_WORDS.has(lower)) {
    return `${prefix}${lower}${suffix}`;
  }

  return `${prefix}${lower.charAt(0).toUpperCase()}${lower.slice(1)}${suffix}`;
}

/** @param {string} text */
export function formatNavLabel(text) {
  const raw = String(text ?? "").trim();
  if (!raw) return raw;

  const tokens = raw.split(/\s+/);
  const last = tokens.length - 1;

  return tokens.map((token, i) => titleCaseToken(token, i === 0 || i === last)).join(" ");
}
