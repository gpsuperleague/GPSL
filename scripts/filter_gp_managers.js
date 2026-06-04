/**
 * eFHUB-style filter: every team playstyle proficiency <= MAX (default 87).
 * Data: https://github.com/amine250/efootball-managers (community, not live GP shop).
 *
 * Usage: node scripts/filter_gp_managers.js
 *        node scripts/filter_gp_managers.js 85
 */

const MANAGERS_URL =
  "https://raw.githubusercontent.com/amine250/efootball-managers/main/data/managers.json";

const STYLES = [
  "possessionGame",
  "quickCounter",
  "longBallCounter",
  "outWide",
  "longBall",
];

const STYLE_LABELS = {
  possessionGame: "Possession",
  quickCounter: "Quick Counter",
  longBallCounter: "LBC",
  outWide: "Out Wide",
  longBall: "Long Ball",
};

async function main() {
  const max = Number(process.argv[2]) || 87;
  const res = await fetch(MANAGERS_URL);
  if (!res.ok) throw new Error(`Fetch failed: ${res.status}`);
  const all = await res.json();

  const matched = all
    .filter((m) => {
      const p = m.teamPlaystyleProficiency || {};
      return STYLES.every((k) => (p[k] ?? 99) <= max);
    })
    .sort((a, b) => a.name.localeCompare(b.name));

  console.log(`Managers with ALL playstyles <= ${max}: ${matched.length} / ${all.length}\n`);
  console.log(
    "Name".padEnd(22) +
      STYLES.map((k) => STYLE_LABELS[k].padStart(10)).join("") +
      "  Link-Up"
  );
  console.log("-".repeat(75));

  for (const m of matched) {
    const p = m.teamPlaystyleProficiency;
    const cols = STYLES.map((k) => String(p[k] ?? "").padStart(10)).join("");
    console.log(`${m.name.padEnd(22)}${cols}  ${m.linkUpPlay ? "yes" : "no"}`);
  }

  console.log("\nSources for a fuller GP Standard list:");
  console.log("  • In-game: Contract → Manager List (authoritative, rotates)");
  console.log("  • eFHUB app / https://www.efootballhub.net/.../search/coaches (filter in UI)");
  console.log("  • https://efootball-world.com/manager");
  console.log("  • Game8 / F2P guides (names + GP prices, manual)");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
