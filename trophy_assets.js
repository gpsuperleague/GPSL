/** Trophy PNG paths and competition page theme tokens. */

export const TROPHY_IMAGES = {
  superleague: "images/trophies/superleague.png",
  championship: "images/trophies/championship.png",
  championship_a: "images/trophies/championship.png",
  championship_b: "images/trophies/championship.png",
  super8: "images/trophies/super8.png",
  plate: "images/trophies/plate.png",
  shield: "images/trophies/shield.png",
  bowl: "images/trophies/bowl.png",
  spoon: "images/trophies/bowl.png",
  league_cup: "images/trophies/league_cup.png",
  world_cup: "images/trophies/world_cup.png",
};

export const CUP_THEME_CLASSES = {
  super8: "theme-cup-super8",
  plate: "theme-cup-plate",
  shield: "theme-cup-shield",
  bowl: "theme-cup-bowl",
  spoon: "theme-cup-bowl",
  league_cup: "theme-cup-league-cup",
};

export const CUP_THEME_TAGLINES = {
  super8: "GPSL elite knockout — Champions League spirit",
  plate: "Mid-table SuperLeague & top Championship — Europa League spirit",
  shield: "Championship mid-tier — Conference League spirit",
  bowl: "Lower-tier Championship knockout — GPSL Bowl",
  league_cup: "All 60 clubs — League Cup knockout",
};

export function trophyImageForCup(cupCode) {
  if (!cupCode) return null;
  if (cupCode === "spoon") return TROPHY_IMAGES.bowl;
  return TROPHY_IMAGES[cupCode] || null;
}

export function cupThemeClass(cupCode) {
  if (!cupCode) return "";
  return CUP_THEME_CLASSES[cupCode] || CUP_THEME_CLASSES.bowl;
}

export function applyCupPageTheme(cupCode) {
  const body = document.body;
  if (!body) return;
  body.classList.remove(
    "theme-cup-super8",
    "theme-cup-plate",
    "theme-cup-shield",
    "theme-cup-bowl",
    "theme-cup-league-cup"
  );
  const cls = cupThemeClass(cupCode);
  if (cls) body.classList.add(cls);
}

export function renderCupHero(cupCode, label) {
  const img = trophyImageForCup(cupCode);
  const tagline = CUP_THEME_TAGLINES[cupCode === "spoon" ? "bowl" : cupCode] || "";
  if (!img) return "";
  return `
    <header class="comp-hero comp-hero--cup">
      <img class="comp-hero-trophy" src="${img}" alt="${label || cupCode} trophy" width="88" height="110">
      <div class="comp-hero-text">
        <p class="comp-hero-kicker">GPSL Cup competition</p>
        <h1 class="comp-hero-title">${label || cupCode}</h1>
        ${tagline ? `<p class="comp-hero-tagline">${tagline}</p>` : ""}
      </div>
    </header>`;
}
