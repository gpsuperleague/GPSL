/** Trophy cabinet — three shelves, fifteen places, overflow in the store room. */

import { TROPHY_IMAGES } from "./trophy_assets.js?v=20261122-plate-fit";
import { formatSeasonStripLabel } from "./season_transfer_schedule.js";

export const CABINET_SHELF_COUNT = 3;
export const CABINET_SLOTS_PER_SHELF = 5;

const HONOURS_NAMES = {
  superleague: "Super League",
  championship_a: "Championship A",
  championship_b: "Championship B",
  league_cup: "League Cup",
  super8: "Super8",
  plate: "Plate",
  shield: "Shield",
  bowl: "Bowl",
  spoon: "Bowl",
};

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function honourKey(honour) {
  const detail =
    honour?.honour_type === "league_champion"
      ? honour.division || ""
      : honour?.cup_code || "";
  return `${honour?.honour_type || ""}|${honour?.season_label ?? ""}|${detail}`;
}

export function honourName(honour) {
  if (!honour) return "Trophy";
  if (honour.honour_type === "league_champion") {
    return HONOURS_NAMES[honour.division] || honour.honour_label || "League title";
  }
  if (honour.honour_type === "cup_winner") {
    const cup = honour.cup_code === "spoon" ? "bowl" : honour.cup_code;
    return HONOURS_NAMES[cup] || honour.honour_label || "Cup";
  }
  return honour.honour_label || "Trophy";
}

function honourImage(honour) {
  if (!honour) return "";
  if (honour.honour_type === "league_champion") {
    if (honour.division === "superleague") return TROPHY_IMAGES.superleague;
    if (honour.division === "championship_a" || honour.division === "championship_b") {
      return TROPHY_IMAGES.championship;
    }
  }
  if (honour.honour_type === "cup_winner") {
    const cup = honour.cup_code === "spoon" ? "bowl" : honour.cup_code;
    return TROPHY_IMAGES[cup] || "";
  }
  return "";
}

function cabinetSeasonText(raw) {
  return formatSeasonStripLabel(raw) || String(raw ?? "");
}

function compareHonours(a, b) {
  const ta = Date.parse(a?.honoured_at || "") || 0;
  const tb = Date.parse(b?.honoured_at || "") || 0;
  if (ta !== tb) return ta - tb;
  const sa = Number(String(a?.season_label || "").match(/\d+/)?.[0] || 0);
  const sb = Number(String(b?.season_label || "").match(/\d+/)?.[0] || 0);
  if (sa !== sb) return sa - sb;
  return honourName(a).localeCompare(honourName(b)) || honourKey(a).localeCompare(honourKey(b));
}

/** Build URL to final tables or cup bracket for an archived honour. */
export function trophyHonourHref(honour) {
  if (!honour?.season_label) return null;
  const season = encodeURIComponent(honour.season_label);
  if (honour.honour_type === "league_champion" && honour.division) {
    const div = encodeURIComponent(honour.division);
    return `progress.html?season=${season}&division=${div}`;
  }
  if (honour.honour_type === "cup_winner" && honour.cup_code) {
    const cup = honour.cup_code === "spoon" ? "bowl" : honour.cup_code;
    return `cups.html?cup=${encodeURIComponent(cup)}&season=${season}`;
  }
  return null;
}

export function arrangeCabinet(honours, places) {
  const rows = honours || [];
  const byKey = new Map();
  for (const honour of rows) byKey.set(honourKey(honour), honour);

  const explicit = new Map();
  for (const place of places || []) {
    if (!place?.honour_key || !byKey.has(place.honour_key)) continue;
    explicit.set(place.honour_key, place);
  }

  const shelves = Array.from({ length: CABINET_SHELF_COUNT }, () =>
    Array(CABINET_SLOTS_PER_SHELF).fill(null)
  );
  const stored = [];

  for (const [key, place] of explicit) {
    const honour = byKey.get(key);
    const onShelf =
      !place.stored &&
      Number.isInteger(Number(place.shelf)) &&
      Number.isInteger(Number(place.slot));
    const shelf = Number(place.shelf);
    const slot = Number(place.slot);
    if (
      onShelf &&
      shelf >= 0 &&
      shelf < CABINET_SHELF_COUNT &&
      slot >= 0 &&
      slot < CABINET_SLOTS_PER_SHELF &&
      !shelves[shelf][slot]
    ) {
      shelves[shelf][slot] = honour;
    } else {
      stored.push(honour);
    }
  }

  const rest = [...byKey.values()].filter((honour) => !explicit.has(honourKey(honour)));
  rest.sort(compareHonours);
  for (const honour of rest) {
    let placed = false;
    for (let shelf = 0; shelf < shelves.length && !placed; shelf += 1) {
      for (let slot = 0; slot < shelves[shelf].length; slot += 1) {
        if (!shelves[shelf][slot]) {
          shelves[shelf][slot] = honour;
          placed = true;
          break;
        }
      }
    }
    if (!placed) stored.push(honour);
  }

  stored.sort(compareHonours);
  return { shelves, stored };
}

export function placesFromLayout(shelves, stored) {
  const places = [];
  shelves.forEach((row, shelf) => {
    row.forEach((honour, slot) => {
      if (!honour) return;
      places.push({
        honour_key: honourKey(honour),
        shelf,
        slot,
        stored: false,
      });
    });
  });
  for (const honour of stored) {
    places.push({
      honour_key: honourKey(honour),
      shelf: null,
      slot: null,
      stored: true,
    });
  }
  return places;
}

export function relocateHonour(honours, places, key, dest) {
  const layout = arrangeCabinet(honours, places);
  const shelves = layout.shelves.map((row) => row.slice());
  const stored = layout.stored.slice();

  let from = null;
  let honour = null;
  for (let shelf = 0; shelf < shelves.length && !honour; shelf += 1) {
    for (let slot = 0; slot < shelves[shelf].length; slot += 1) {
      if (shelves[shelf][slot] && honourKey(shelves[shelf][slot]) === key) {
        honour = shelves[shelf][slot];
        shelves[shelf][slot] = null;
        from = { shelf, slot };
        break;
      }
    }
  }
  if (!honour) {
    const index = stored.findIndex((item) => honourKey(item) === key);
    if (index >= 0) {
      honour = stored.splice(index, 1)[0];
      from = { stored: true };
    }
  }
  if (!honour) return placesFromLayout(shelves, stored);

  if (dest?.stored) {
    stored.push(honour);
    return placesFromLayout(shelves, stored);
  }

  const shelf = Number(dest?.shelf);
  const slot = Number(dest?.slot);
  if (
    !Number.isInteger(shelf) ||
    !Number.isInteger(slot) ||
    shelf < 0 ||
    shelf >= shelves.length ||
    slot < 0 ||
    slot >= shelves[shelf].length
  ) {
    if (from?.stored) stored.push(honour);
    else if (from) shelves[from.shelf][from.slot] = honour;
    return placesFromLayout(shelves, stored);
  }

  const other = shelves[shelf][slot];
  shelves[shelf][slot] = honour;
  if (other && honourKey(other) !== key) {
    if (from?.stored) stored.push(other);
    else if (from) shelves[from.shelf][from.slot] = other;
  }
  return placesFromLayout(shelves, stored);
}

function renderTrophyFigure(honour, canArrange) {
  const seasonLabel = cabinetSeasonText(honour.season_label);
  const name = honourName(honour);
  const href = trophyHonourHref(honour);
  const image = honourImage(honour);
  const title = canArrange
    ? `${seasonLabel} ${name}. Drag to another place, or onto the store-room door.`
    : href
      ? `View ${seasonLabel} ${name}`
      : `${seasonLabel} ${name}`;
  const picture = image
    ? `<img class="trophy-png" src="${esc(image)}" alt="" width="56" height="72" draggable="false">`
    : `<span class="trophy-png trophy-png--blank" aria-hidden="true"></span>`;
  const body = `
      ${picture}
      <span class="trophy-caption">
        <span class="trophy-caption-name">${esc(name)}</span>
        <span class="trophy-season">${esc(seasonLabel)}</span>
      </span>`;
  const attrs = `class="trophy-on-shelf${href ? " trophy-link" : ""}" data-honour-key="${esc(honourKey(honour))}" title="${esc(title)}"${canArrange ? ' draggable="true"' : ""}`;
  if (href) {
    return `<a ${attrs} href="${esc(href)}">${body}</a>`;
  }
  return `<figure ${attrs}>${body}</figure>`;
}

function renderSlot(shelf, slot, honour, canArrange) {
  if (!honour) {
    return `
      <div class="trophy-slot is-empty" data-shelf="${shelf}" data-slot="${slot}">
        <span class="trophy-slot-pad" aria-hidden="true"></span>
      </div>`;
  }
  return `
    <div class="trophy-slot has-trophy" data-shelf="${shelf}" data-slot="${slot}">
      ${renderTrophyFigure(honour, canArrange)}
    </div>`;
}

function renderStoredItem(honour, canArrange) {
  const seasonLabel = cabinetSeasonText(honour.season_label);
  const name = honourName(honour);
  const image = honourImage(honour);
  const picture = image
    ? `<img src="${esc(image)}" alt="" width="36" height="46" draggable="false">`
    : "";
  const restore = canArrange
    ? `<button type="button" class="trophy-restore" data-honour-key="${esc(honourKey(honour))}">Put on shelf</button>`
    : "";
  return `
    <li class="trophy-stored" data-honour-key="${esc(honourKey(honour))}"${canArrange ? ' draggable="true"' : ""}>
      ${picture}
      <span class="trophy-stored-label">${esc(name)}<small>${esc(seasonLabel)}</small></span>
      ${restore}
    </li>`;
}

export function renderTrophyCabinet(honours, options = {}) {
  const rows = honours || [];
  const canArrange = options.canArrange === true;
  const layout = arrangeCabinet(rows, options.places || []);
  const storeOpen = options.storeOpen === true;
  const status = options.status || "";
  const shelves = layout.shelves
    .map((row, shelf) => {
      const slots = row.map((honour, slot) => renderSlot(shelf, slot, honour, canArrange)).join("");
      return `
        <section class="cabinet-shelf" aria-label="Shelf ${shelf + 1}">
          <div class="shelf-board">
            <div class="shelf-slots">${slots}</div>
          </div>
        </section>`;
    })
    .join("");
  const emptyNote = rows.length
    ? ""
    : `<p class="trophy-cabinet-empty">No trophies yet. Wins appear on the shelves when a season is archived.</p>`;
  const storedItems = layout.stored.map((honour) => renderStoredItem(honour, canArrange)).join("");
  const storedEmpty = layout.stored.length
    ? ""
    : `<p class="trophy-store-empty">Nothing is in the store room.</p>`;
  const count = layout.stored.length
    ? `<span class="trophy-store-count">${layout.stored.length}</span>`
    : "";

  return `
    <div class="trophy-cabinet${rows.length ? " has-wins" : ""}${canArrange ? " can-arrange" : ""}">
      <div class="trophy-cabinet-cornice" aria-hidden="true">
        <span class="trophy-cabinet-nameplate">Honours</span>
      </div>
      <div class="trophy-cabinet-body">
        <div class="trophy-cabinet-case">
          <span class="trophy-cabinet-hinge trophy-cabinet-hinge--left trophy-cabinet-hinge--high" aria-hidden="true"></span>
          <span class="trophy-cabinet-hinge trophy-cabinet-hinge--left trophy-cabinet-hinge--low" aria-hidden="true"></span>
          <span class="trophy-cabinet-hinge trophy-cabinet-hinge--right trophy-cabinet-hinge--high" aria-hidden="true"></span>
          <span class="trophy-cabinet-hinge trophy-cabinet-hinge--right trophy-cabinet-hinge--low" aria-hidden="true"></span>
          <div class="trophy-cabinet-glass">
            ${emptyNote}
            ${shelves}
          </div>
        </div>
        <button type="button" class="trophy-store-door${storeOpen ? " is-open" : ""}" aria-expanded="${storeOpen ? "true" : "false"}">
          <span class="trophy-store-door-plate">Store room</span>
          ${count}
        </button>
      </div>
      <div class="trophy-cabinet-plinth" aria-hidden="true"></div>
      <div class="trophy-store-room"${storeOpen ? "" : " hidden"}>
        <p class="trophy-store-lead">${canArrange ? "Drag a trophy onto a shelf, or onto one already there to swap. Put on shelf uses the first empty place." : "Trophies kept off the shelves."}</p>
        <p class="trophy-cabinet-status"${status ? "" : " hidden"}>${esc(status)}</p>
        ${storedEmpty}
        <ul class="trophy-store-list">${storedItems}</ul>
      </div>
    </div>`;
}

export function bindTrophyCabinet(root, options = {}) {
  if (!root) return;
  const { honours = [], places = [], canArrange = false, onCommit } = options;
  const door = root.querySelector(".trophy-store-door");
  const room = root.querySelector(".trophy-store-room");

  if (door && room) {
    door.addEventListener("click", (event) => {
      if (root.dataset.suppressClick === "1") {
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      const open = room.hidden;
      room.hidden = !open;
      door.setAttribute("aria-expanded", open ? "true" : "false");
      door.classList.toggle("is-open", open);
    });
  }

  if (!canArrange || typeof onCommit !== "function") return;

  let draggedKey = "";

  root.addEventListener("dragstart", (event) => {
    const item = event.target.closest?.("[data-honour-key]");
    if (!item || !root.contains(item)) return;
    draggedKey = item.getAttribute("data-honour-key") || "";
    event.dataTransfer?.setData("text/plain", draggedKey);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
    item.classList.add("is-dragging");
  });

  root.addEventListener("dragend", (event) => {
    event.target.closest?.("[data-honour-key]")?.classList.remove("is-dragging");
    root.querySelectorAll(".is-drop").forEach((node) => node.classList.remove("is-drop"));
    root.dataset.suppressClick = "1";
    window.setTimeout(() => {
      root.dataset.suppressClick = "";
    }, 120);
  });

  root.addEventListener("click", (event) => {
    if (root.dataset.suppressClick === "1") {
      event.preventDefault();
      event.stopPropagation();
    }
  });

  root.addEventListener("dragover", (event) => {
    const zone = event.target.closest?.(".trophy-slot, .trophy-store-door");
    if (!zone || !root.contains(zone)) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    root.querySelectorAll(".is-drop").forEach((node) => node.classList.remove("is-drop"));
    zone.classList.add("is-drop");
  });

  root.addEventListener("drop", (event) => {
    const zone = event.target.closest?.(".trophy-slot, .trophy-store-door");
    if (!zone || !root.contains(zone)) return;
    event.preventDefault();
    zone.classList.remove("is-drop");
    const key = event.dataTransfer?.getData("text/plain") || draggedKey;
    if (!key) return;
    const dest = zone.classList.contains("trophy-store-door")
      ? { stored: true }
      : { shelf: Number(zone.dataset.shelf), slot: Number(zone.dataset.slot) };
    onCommit(relocateHonour(honours, places, key, dest));
  });

  root.querySelectorAll(".trophy-restore").forEach((button) => {
    button.addEventListener("click", () => {
      const key = button.getAttribute("data-honour-key");
      const layout = arrangeCabinet(honours, places);
      let dest = null;
      for (let shelf = 0; shelf < layout.shelves.length && !dest; shelf += 1) {
        for (let slot = 0; slot < layout.shelves[shelf].length; slot += 1) {
          if (!layout.shelves[shelf][slot]) {
            dest = { shelf, slot };
            break;
          }
        }
      }
      const status = root.querySelector(".trophy-cabinet-status");
      if (!dest) {
        if (status) {
          status.hidden = false;
          status.textContent =
            "The shelves are full. Drag this trophy onto one on display to swap them.";
        }
        return;
      }
      onCommit(relocateHonour(honours, places, key, dest));
    });
  });
}

/** Sample honours for cabinet preview / forecast page (not live data). */
export const TROPHY_CABINET_PREVIEW_SCENARIOS = [
  {
    id: "empty",
    title: "New club — empty cabinet",
    blurb: "Three shelves stay bare until a season is archived.",
    honours: [],
  },
  {
    id: "first_win",
    title: "First honours — one league title and one cup",
    blurb: "The first wins stand on the top shelf, left to right.",
    honours: [
      {
        honour_type: "league_champion",
        division: "superleague",
        season_label: "1",
      },
      {
        honour_type: "cup_winner",
        cup_code: "league_cup",
        season_label: "1",
      },
    ],
  },
  {
    id: "repeat_cup",
    title: "Same cup twice",
    blurb: "Winning Super8 again adds a second trophy on the next place, with its own season tag.",
    honours: [
      {
        honour_type: "cup_winner",
        cup_code: "super8",
        season_label: "1",
      },
      {
        honour_type: "cup_winner",
        cup_code: "super8",
        season_label: "2",
      },
    ],
  },
  {
    id: "full",
    title: "A cabinet after several seasons",
    blurb: "Trophies stand in a row. Drag one to another place, or onto the store-room door. This preview is not saved.",
    honours: [
      { honour_type: "league_champion", division: "superleague", season_label: "5" },
      { honour_type: "league_champion", division: "superleague", season_label: "8" },
      { honour_type: "league_champion", division: "championship_a", season_label: "3" },
      { honour_type: "cup_winner", cup_code: "league_cup", season_label: "4" },
      { honour_type: "cup_winner", cup_code: "league_cup", season_label: "9" },
      { honour_type: "cup_winner", cup_code: "super8", season_label: "6" },
      { honour_type: "cup_winner", cup_code: "super8", season_label: "8" },
      { honour_type: "cup_winner", cup_code: "plate", season_label: "7" },
      { honour_type: "cup_winner", cup_code: "shield", season_label: "2" },
      { honour_type: "cup_winner", cup_code: "bowl", season_label: "1" },
    ],
  },
  {
    id: "overflow",
    title: "More wins than places — the store room",
    blurb: "Fifteen trophies fit on the shelves. The next one waits behind the store-room door until the owner brings it out.",
    honours: ["league_cup", "super8", "plate", "shield"].flatMap((cup) =>
      [1, 2, 3, 4].map((season) => ({
        honour_type: "cup_winner",
        cup_code: cup,
        season_label: String(season),
      }))
    ),
  },
];
