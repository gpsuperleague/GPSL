/**
 * Goal.com NXGN helpers — default URL + GPDB name-search variants.
 * Live player lists come from the nextgen-goal-fetch edge function
 * using the admin-editable source URL.
 */

export const NXGN_DEFAULT_SOURCE_URL =
  "https://www.goal.com/en/lists/nxgn-2026-best-teenage-wonderkids-football/blt2f8486395140dacd";

/** @deprecated use NXGN_DEFAULT_SOURCE_URL */
export const NXGN_2026_SOURCE_URL = NXGN_DEFAULT_SOURCE_URL;

/**
 * Extra search strings for awkward PESDB / accent spellings.
 * @param {{ name?: string }} entry
 * @returns {string[]}
 */
export function nxgnSearchQueries(entry) {
  const name = String(entry?.name || "").trim();
  if (!name) return [];
  const parts = name.split(/\s+/).filter(Boolean);
  const queries = [name];

  // Common Goal → PESDB spelling gaps
  const aliases = {
    Estevao: ["Estevão", "Estevao Willian"],
    "Pau Cubarsi": ["Cubarsí", "Cubarsi"],
    "Joao Simoes": ["João Simões", "Simoes"],
    "Anisio Cabral": ["Anísio Cabral"],
    "Alvaro Montoro": ["Álvaro Montoro"],
    "Kerim Alajbegovic": ["Alajbegović"],
    "Andrija Maksimovic": ["Maksimović"],
    "Luka Vuskovic": ["Vušković", "Vuskovic"],
    "Kendry Paez": ["Páez", "Paez"],
    "Mohamed Kader Meite": ["Meïté", "Meite", "Kader Meite"],
    "Dro Fernandez": ["Fernández", "Dro Fernández"],
    "Charalampos Kostoulas": ["Kostoulas"],
    "Konstantinos Karetsas": ["Karetsas"],
  };
  for (const a of aliases[name] || []) queries.push(a);

  if (parts.length >= 2) queries.push(parts[parts.length - 1]);
  return [...new Set(queries)];
}

/** @deprecated use nxgnSearchQueries */
export const nxgn2026SearchQueries = nxgnSearchQueries;
