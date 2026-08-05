/**
 * Goal.com NXGN 2026 — men's top 50 teenage wonderkids
 * Source: https://www.goal.com/en/lists/nxgn-2026-best-teenage-wonderkids-football/blt2f8486395140dacd
 * (born on or after 1 Jan 2007)
 */

export const NXGN_2026_SOURCE_URL =
  "https://www.goal.com/en/lists/nxgn-2026-best-teenage-wonderkids-football/blt2f8486395140dacd";

/** @type {{ rank: number, name: string, club: string }[]} */
export const NXGN_2026_PLAYERS = [
  { rank: 1, name: "Lamine Yamal", club: "Barcelona" },
  { rank: 2, name: "Estevao", club: "Chelsea" },
  { rank: 3, name: "Pau Cubarsi", club: "Barcelona" },
  { rank: 4, name: "Franco Mastantuono", club: "Real Madrid" },
  { rank: 5, name: "Lennart Karl", club: "Bayern Munich" },
  { rank: 6, name: "Max Dowman", club: "Arsenal" },
  { rank: 7, name: "Luka Vuskovic", club: "Tottenham" },
  { rank: 8, name: "Ayyoub Bouaddi", club: "Lille" },
  { rank: 9, name: "Geovany Quenda", club: "Sporting CP" },
  { rank: 10, name: "Ethan Nwaneri", club: "Arsenal" },
  { rank: 11, name: "Rodrigo Mora", club: "Porto" },
  { rank: 12, name: "Honest Ahanor", club: "Atalanta" },
  { rank: 13, name: "Ibrahim Mbaye", club: "Paris Saint-Germain" },
  { rank: 14, name: "Konstantinos Karetsas", club: "Genk" },
  { rank: 15, name: "Rio Ngumoha", club: "Liverpool" },
  { rank: 16, name: "Gilberto Mora", club: "Club Tijuana" },
  { rank: 17, name: "Marc Bernal", club: "Barcelona" },
  { rank: 18, name: "Dro Fernandez", club: "Paris Saint-Germain" },
  { rank: 19, name: "Mohamed Kader Meite", club: "Al-Hilal" },
  { rank: 20, name: "Kendry Paez", club: "Chelsea" },
  { rank: 21, name: "Jorthy Mokio", club: "Ajax" },
  { rank: 22, name: "Francesco Camarda", club: "AC Milan" },
  { rank: 23, name: "Robinio Vaz", club: "Roma" },
  { rank: 24, name: "Josh King", club: "Fulham" },
  { rank: 25, name: "Charalampos Kostoulas", club: "Brighton" },
  { rank: 26, name: "Mikey Moore", club: "Tottenham" },
  { rank: 27, name: "Kennet Eichhorn", club: "Hertha Berlin" },
  { rank: 28, name: "Tylel Tati", club: "Nantes" },
  { rank: 29, name: "Nathan De Cat", club: "Anderlecht" },
  { rank: 30, name: "Mateus Mane", club: "Wolves" },
  { rank: 31, name: "Andrija Maksimovic", club: "RB Leipzig" },
  { rank: 32, name: "Sean Steur", club: "Ajax" },
  { rank: 33, name: "Kerim Alajbegovic", club: "Red Bull Salzburg" },
  { rank: 34, name: "Vasilije Kostov", club: "Red Star Belgrade" },
  { rank: 35, name: "Quentin Ndjantou", club: "Paris Saint-Germain" },
  { rank: 36, name: "Ian Subiabre", club: "River Plate" },
  { rank: 37, name: "Chris Rigg", club: "Sunderland" },
  { rank: 38, name: "Karim Coulibaly", club: "Werder Bremen" },
  { rank: 39, name: "Cavan Sullivan", club: "Philadelphia Union" },
  { rank: 40, name: "Thiago Pitarch", club: "Real Madrid" },
  { rank: 41, name: "Viktor Dadason", club: "FC Copenhagen" },
  { rank: 42, name: "Alvaro Montoro", club: "Botafogo" },
  { rank: 43, name: "Dastan Satpaev", club: "Kairat Almaty" },
  { rank: 44, name: "Samuele Inacio", club: "Borussia Dortmund" },
  { rank: 45, name: "Oskar Pietuszewski", club: "Porto" },
  { rank: 46, name: "Jeremy Monga", club: "Leicester City" },
  { rank: 47, name: "Joan Martinez", club: "Real Madrid" },
  { rank: 48, name: "Anisio Cabral", club: "Benfica" },
  { rank: 49, name: "Joao Simoes", club: "Sporting CP" },
  { rank: 50, name: "JJ Gabriel", club: "Manchester United" },
];

export function nxgn2026SearchQueries(entry) {
  const name = String(entry?.name || "").trim();
  if (!name) return [];
  const parts = name.split(/\s+/).filter(Boolean);
  const queries = [name];
  // Accent-less / short variants help PESDB naming
  if (name === "Estevao") queries.push("Estevão", "Estevao Willian");
  if (name === "Pau Cubarsi") queries.push("Cubarsí", "Cubarsi");
  if (name === "Joao Simoes") queries.push("João Simões", "Simoes");
  if (name === "Anisio Cabral") queries.push("Anísio Cabral");
  if (name === "Alvaro Montoro") queries.push("Álvaro Montoro");
  if (name === "Kerim Alajbegovic") queries.push("Alajbegović", "Karim Alajbegovic");
  if (name === "Andrija Maksimovic") queries.push("Maksimović");
  if (name === "Luka Vuskovic") queries.push("Vušković", "Vuskovic");
  if (name === "Kendry Paez") queries.push("Páez", "Paez");
  if (name === "Mohamed Kader Meite") queries.push("Meïté", "Meite");
  if (name === "Dro Fernandez") queries.push("Fernández", "Dro Fernández");
  if (name === "Charalampos Kostoulas") queries.push("Kostoulas");
  if (name === "Konstantinos Karetsas") queries.push("Karetsas");
  if (parts.length >= 2) queries.push(parts[parts.length - 1]);
  return [...new Set(queries)];
}
