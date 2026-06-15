import { initGlobal } from "./global.js";
import {
  renderTrophyCabinet,
  TROPHY_CABINET_PREVIEW_SCENARIOS,
} from "./history_trophies.js";

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderScenarioBlock(scenario) {
  return `
    <section class="preview-scenario" id="preview-${esc(scenario.id)}">
      <h2>${esc(scenario.title)}</h2>
      <p class="blurb">${esc(scenario.blurb)}</p>
      ${renderTrophyCabinet(scenario.honours)}
    </section>`;
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
