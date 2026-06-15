/** Trophy cabinet — honours from archive appear on wooden shelves (one figure per win). */

import { TROPHY_IMAGES } from "./trophy_assets.js";

export const TROPHY_CABINET_SHELVES = [
  {
    id: "league",
    label: "League titles",
    slots: [
      {
        id: "superleague",
        label: "SuperLeague",
        image: TROPHY_IMAGES.superleague,
        match: (h) =>
          h.honour_type === "league_champion" && h.division === "superleague",
      },
      {
        id: "championship_a",
        label: "Championship A",
        image: TROPHY_IMAGES.championship,
        match: (h) =>
          h.honour_type === "league_champion" && h.division === "championship_a",
      },
      {
        id: "championship_b",
        label: "Championship B",
        image: TROPHY_IMAGES.championship,
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
        image: TROPHY_IMAGES.league_cup,
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "league_cup",
      },
      {
        id: "super8",
        label: "Super8",
        image: TROPHY_IMAGES.super8,
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "super8",
      },
      {
        id: "plate",
        label: "Plate",
        image: TROPHY_IMAGES.plate,
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "plate",
      },
      {
        id: "shield",
        label: "Shield",
        image: TROPHY_IMAGES.shield,
        match: (h) => h.honour_type === "cup_winner" && h.cup_code === "shield",
      },
      {
        id: "bowl",
        label: "Bowl",
        image: TROPHY_IMAGES.bowl,
        match: (h) =>
          h.honour_type === "cup_winner" &&
          (h.cup_code === "bowl" || h.cup_code === "spoon"),
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

function renderTrophyOnShelf(imageSrc, seasonLabel) {
  return `
    <figure class="trophy-on-shelf" title="${esc(seasonLabel)}">
      <img class="trophy-png" src="${esc(imageSrc)}" alt="${esc(seasonLabel)} trophy" width="56" height="72" loading="lazy">
      <figcaption class="trophy-season">${esc(seasonLabel)}</figcaption>
    </figure>`;
}

function renderEmptyBay(slot) {
  return `
    <div class="trophy-bay is-empty" data-trophy="${esc(slot.id)}">
      <div class="trophy-bay-label">${esc(slot.label)}</div>
      <div class="trophy-bay-surface">
        <span class="trophy-bay-empty">—</span>
      </div>
    </div>`;
}

function renderBay(slot, honours) {
  const wins = (honours || [])
    .filter(slot.match)
    .sort((a, b) => String(b.season_label).localeCompare(String(a.season_label)));

  if (!wins.length) {
    return renderEmptyBay(slot);
  }

  const figures = wins
    .map((w) => renderTrophyOnShelf(slot.image, w.season_label))
    .join("");

  return `
    <div class="trophy-bay has-trophies" data-trophy="${esc(slot.id)}">
      <div class="trophy-bay-label">${esc(slot.label)}</div>
      <div class="trophy-bay-surface">${figures}</div>
    </div>`;
}

function renderShelf(shelf, honours) {
  const bays = shelf.slots.map((slot) => renderBay(slot, honours)).join("");
  return `
    <section class="cabinet-shelf" data-shelf="${esc(shelf.id)}" aria-label="${esc(shelf.label)}">
      <div class="shelf-plaque">${esc(shelf.label)}</div>
      <div class="shelf-board">
        <div class="shelf-bays">${bays}</div>
      </div>
    </section>`;
}

export function renderTrophyCabinet(honours) {
  const rows = honours || [];
  const totalWins = rows.length;
  const shelves = TROPHY_CABINET_SHELVES.map((s) => renderShelf(s, rows)).join("");

  const emptyNote = totalWins
    ? ""
    : `<p class="trophy-cabinet-empty">No trophies yet — wins appear here on the shelf when a season is archived.</p>`;

  return `
    <div class="trophy-cabinet${totalWins ? " has-wins" : ""}">
      <div class="trophy-cabinet-glass">
        ${emptyNote}
        ${shelves}
      </div>
    </div>`;
}
