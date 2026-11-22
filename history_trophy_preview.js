import { initGlobal } from "./global.js";
import {
  renderTrophyCabinet,
  bindTrophyCabinet,
  TROPHY_CABINET_PREVIEW_SCENARIOS,
} from "./history_trophies.js?v=20261122-select";

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const previewPlaces = {};
const previewOpen = {};

function renderScenarioBlock(scenario) {
  return `
    <section class="preview-scenario" id="preview-${esc(scenario.id)}" data-scenario="${esc(scenario.id)}">
      <h2>${esc(scenario.title)}</h2>
      <p class="blurb">${esc(scenario.blurb)}</p>
      <div class="preview-cabinet">
        ${renderTrophyCabinet(scenario.honours, {
          canArrange: true,
          places: previewPlaces[scenario.id] || [],
          storeOpen: previewOpen[scenario.id] === true,
        })}
      </div>
    </section>`;
}

function bindScenario(section) {
  const id = section?.dataset?.scenario;
  const scenario = TROPHY_CABINET_PREVIEW_SCENARIOS.find((item) => item.id === id);
  const mount = section?.querySelector(".preview-cabinet");
  const cabinet = mount?.querySelector(".trophy-cabinet");
  if (!scenario || !mount || !cabinet) return;
  bindTrophyCabinet(cabinet, {
    honours: scenario.honours,
    places: previewPlaces[id] || [],
    canArrange: true,
    onCommit(nextPlaces) {
      const room = cabinet.querySelector(".trophy-store-room");
      previewOpen[id] = !!room && !room.hidden;
      previewPlaces[id] = nextPlaces;
      mount.innerHTML = renderTrophyCabinet(scenario.honours, {
        canArrange: true,
        places: nextPlaces,
        storeOpen: previewOpen[id],
      });
      bindScenario(section);
    },
  });
}

function bindHost(host) {
  host.querySelectorAll("[data-scenario]").forEach((section) => bindScenario(section));
}

function renderSingle(scenarioId) {
  const scenario =
    TROPHY_CABINET_PREVIEW_SCENARIOS.find((s) => s.id === scenarioId) ||
    TROPHY_CABINET_PREVIEW_SCENARIOS[0];
  return renderScenarioBlock(scenario);
}

function renderAll() {
  return `<div class="preview-all">${TROPHY_CABINET_PREVIEW_SCENARIOS.map(renderScenarioBlock).join("")}</div>`;
}

function fillScenarioSelect(select) {
  select.innerHTML = `
    <option value="all">All scenarios (scroll)</option>
    ${TROPHY_CABINET_PREVIEW_SCENARIOS.map(
      (s) => `<option value="${esc(s.id)}">${esc(s.title)}</option>`
    ).join("")}`;
}

function applyScenario(scenarioId) {
  const host = document.getElementById("previewHost");
  if (!host) return;
  host.innerHTML = scenarioId === "all" ? renderAll() : renderSingle(scenarioId);
  bindHost(host);
}

function initFromQuery() {
  const params = new URLSearchParams(window.location.search);
  const q = params.get("scenario");
  if (q && (q === "all" || TROPHY_CABINET_PREVIEW_SCENARIOS.some((s) => s.id === q))) {
    return q;
  }
  return "all";
}

async function main() {
  await initGlobal();
  const select = document.getElementById("scenarioPick");
  const host = document.getElementById("previewHost");
  if (!select || !host) return;

  fillScenarioSelect(select);
  const initial = initFromQuery();
  select.value = initial;
  applyScenario(initial);

  select.addEventListener("change", () => {
    applyScenario(select.value);
  });
}

main();
