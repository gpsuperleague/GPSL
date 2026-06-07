/** SVG trophy shapes + cabinet slot config for Club History honours. */

const GOLD = {
  light: "#f5e6a8",
  mid: "#d4af37",
  dark: "#8b6914",
  rim: "#c9a227",
};

const WOOD = {
  light: "#a67c52",
  mid: "#6b4423",
  dark: "#3d2817",
};

const SILVER = {
  light: "#e8e8e8",
  mid: "#b0b0b0",
  dark: "#707070",
};

export const TROPHY_CABINET_SHELVES = [
  {
    id: "league",
    label: "League titles",
    slots: [
      {
        id: "superleague",
        label: "SuperLeague",
        variant: "league-cup",
        match: (h) =>
          h.honour_type === "league_champion" && h.division === "superleague",
      },
      {
        id: "championship_a",
        label: "Championship A",
        variant: "league-cup",
        match: (h) =>
          h.honour_type === "league_champion" && h.division === "championship_a",
      },
      {
        id: "championship_b",
        label: "Championship B",
        variant: "league-cup",
        match: (h) =>
          h.honour_type === "league_champion" && h.division === "championship_b",
      },
    ],
  },
  {
    id: "cups",
    label: "Cup competitions",
    slots: [
      {
        id: "league_cup",
        label: "League Cup",
        variant: "league-cup",
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "league_cup",
      },
      {
        id: "super8",
        label: "Super8",
        variant: "super8",
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "super8",
      },
      {
        id: "plate",
        label: "Plate",
        variant: "plate",
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "plate",
      },
      {
        id: "shield",
        label: "Shield",
        variant: "shield",
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "shield",
      },
      {
        id: "spoon",
        label: "Spoon",
        variant: "spoon",
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "spoon",
      },
    ],
  },
];

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

let trophySvgSeq = 0;

function trophySvg(variant, won) {
  const g = won ? GOLD : SILVER;
  const gradId = `trophy-grad-${variant}-${++trophySvgSeq}`;
  const defs = `
    <defs>
      <linearGradient id="${gradId}" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="${g.light}"/>
        <stop offset="45%" stop-color="${g.mid}"/>
        <stop offset="100%" stop-color="${g.dark}"/>
      </linearGradient>
    </defs>`;
  const fill = `url(#${gradId})`;

  switch (variant) {
    case "super8":
      return `<svg viewBox="0 0 52 68" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        ${defs}
        <ellipse cx="26" cy="62" rx="14" ry="3" fill="#2a1a10"/>
        <rect x="20" y="54" width="12" height="8" rx="1" fill="${fill}"/>
        <path d="M14 18 C14 8 38 8 38 18 L36 42 C36 48 16 48 16 42 Z" fill="${fill}" stroke="${g.rim}" stroke-width="1"/>
        <path d="M10 22 C6 24 6 30 10 32" fill="none" stroke="${g.mid}" stroke-width="2"/>
        <path d="M42 22 C46 24 46 30 42 32" fill="none" stroke="${g.mid}" stroke-width="2"/>
        <text x="26" y="36" text-anchor="middle" font-size="14" font-weight="bold" fill="${won ? "#3d2817" : "#444"}">8</text>
      </svg>`;

    case "plate":
      return `<svg viewBox="0 0 52 68" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        ${defs}
        <ellipse cx="26" cy="62" rx="14" ry="3" fill="#2a1a10"/>
        <rect x="22" y="52" width="8" height="10" fill="${fill}"/>
        <ellipse cx="26" cy="44" rx="16" ry="4" fill="${g.dark}"/>
        <ellipse cx="26" cy="40" rx="20" ry="6" fill="${fill}" stroke="${g.rim}" stroke-width="1"/>
        <ellipse cx="26" cy="38" rx="14" ry="3" fill="${g.light}" opacity="0.45"/>
      </svg>`;

    case "shield":
      return `<svg viewBox="0 0 52 68" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        ${defs}
        <ellipse cx="26" cy="62" rx="14" ry="3" fill="#2a1a10"/>
        <rect x="22" y="52" width="8" height="10" fill="${fill}"/>
        <path d="M26 10 L40 18 L40 36 C40 46 26 54 26 54 C26 54 12 46 12 36 L12 18 Z" fill="${fill}" stroke="${g.rim}" stroke-width="1.2"/>
        <path d="M26 16 L34 21 L34 34 C34 40 26 46 26 46 C26 46 18 40 18 34 L18 21 Z" fill="${g.light}" opacity="0.25"/>
      </svg>`;

    case "spoon": {
      const w = won ? WOOD : SILVER;
      const spoonGrad = `${gradId}-spoon`;
      return `<svg viewBox="0 0 52 68" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <defs>
          <linearGradient id="${spoonGrad}" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stop-color="${w.light}"/>
            <stop offset="50%" stop-color="${w.mid}"/>
            <stop offset="100%" stop-color="${w.dark}"/>
          </linearGradient>
        </defs>
        <ellipse cx="26" cy="62" rx="14" ry="3" fill="#2a1a10"/>
        <rect x="22" y="52" width="8" height="10" fill="url(#${spoonGrad})"/>
        <ellipse cx="26" cy="22" rx="12" ry="14" fill="url(#${spoonGrad})" stroke="${w.dark}" stroke-width="1"/>
        <rect x="24" y="34" width="4" height="20" rx="2" fill="url(#${spoonGrad})"/>
      </svg>`;
    }

    case "league-cup":
    default:
      return `<svg viewBox="0 0 52 68" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        ${defs}
        <ellipse cx="26" cy="62" rx="14" ry="3" fill="#2a1a10"/>
        <rect x="20" y="52" width="12" height="8" rx="1" fill="${fill}"/>
        <path d="M16 20 C16 10 36 10 36 20 L34 44 C34 50 18 50 18 44 Z" fill="${fill}" stroke="${g.rim}" stroke-width="1"/>
        <ellipse cx="26" cy="20" rx="10" ry="3" fill="${g.light}" opacity="0.5"/>
        <path d="M12 24 C8 26 8 32 12 34" fill="none" stroke="${g.mid}" stroke-width="2"/>
        <path d="M40 24 C44 26 44 32 40 34" fill="none" stroke="${g.mid}" stroke-width="2"/>
      </svg>`;
  }
}

function renderTrophyItem(variant, seasonLabel, won) {
  const cls = won ? "trophy-item is-won" : "trophy-item is-ghost";
  const season = won
    ? `<span class="trophy-season">${esc(seasonLabel)}</span>`
    : "";
  return `<div class="${cls}">${trophySvg(variant, won)}${season}</div>`;
}

function renderSlot(slot, honours) {
  const wins = (honours || [])
    .filter(slot.match)
    .sort((a, b) => String(b.season_label).localeCompare(String(a.season_label)));

  const isEmpty = !wins.length;
  const pedestal = isEmpty
    ? renderTrophyItem(slot.variant, null, false)
    : wins.map((w) => renderTrophyItem(slot.variant, w.season_label, true)).join("");

  const countNote =
    wins.length > 1
      ? `<span class="trophy-slot-count">×${wins.length}</span>`
      : "";

  return `
    <div class="trophy-slot${isEmpty ? " is-empty" : ""}" data-trophy="${esc(slot.id)}">
      <div class="trophy-pedestal">${pedestal}</div>
      <div class="trophy-slot-plaque">${esc(slot.label)}${countNote}</div>
    </div>`;
}

function renderShelf(shelf, honours) {
  const slots = shelf.slots.map((slot) => renderSlot(slot, honours)).join("");
  return `
    <section class="cabinet-shelf" data-shelf="${esc(shelf.id)}">
      <div class="shelf-plaque">${esc(shelf.label)}</div>
      <div class="cabinet-row">${slots}</div>
    </section>`;
}

export function renderTrophyCabinet(honours) {
  trophySvgSeq = 0;
  const shelves = TROPHY_CABINET_SHELVES.map((s) => renderShelf(s, honours)).join("");
  const totalWins = (honours || []).length;

  if (!totalWins) {
    return `
      <div class="trophy-cabinet">
        <div class="trophy-cabinet-glass">
          <p class="trophy-cabinet-empty">No trophies in the cabinet yet — league titles and cup wins appear here when seasons are archived.</p>
          ${shelves}
        </div>
      </div>`;
  }

  return `
    <div class="trophy-cabinet">
      <div class="trophy-cabinet-glass">${shelves}</div>
    </div>`;
}
