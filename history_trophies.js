/** Trophy cabinet slot config — PNG assets in images/trophies/ */

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

function renderTrophyItem(imageSrc, seasonLabel, won) {
  const cls = won ? "trophy-item is-won" : "trophy-item is-ghost";
  const season = won
    ? `<span class="trophy-season">${esc(seasonLabel)}</span>`
    : "";
  return `<div class="${cls}">
    <img class="trophy-png" src="${esc(imageSrc)}" alt="" width="52" height="68" loading="lazy">
    ${season}
  </div>`;
}

function renderSlot(slot, honours) {
  const wins = (honours || [])
    .filter(slot.match)
    .sort((a, b) => String(b.season_label).localeCompare(String(a.season_label)));

  const isEmpty = !wins.length;
  const pedestal = isEmpty
    ? renderTrophyItem(slot.image, null, false)
    : wins.map((w) => renderTrophyItem(slot.image, w.season_label, true)).join("");

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
