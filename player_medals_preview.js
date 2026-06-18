import { initGlobal } from "./global.js";
import { loadClubsMap } from "./clubs_lookup.js";
import {
  PLAYER_MEDALS_PREVIEW_SCENARIOS,
  renderHonoursHtml,
} from "./player_career_medals.js";

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderScenarioPanel(scenario) {
  const emptyMsg =
    "No winner medals yet — league titles and cups appear after season archive (5+ league apps or 1+ cup app with the winning club).";

  return `
    <section class="preview-scenario" id="preview-${esc(scenario.id)}">
      <h2>${esc(scenario.title)}</h2>
      <p class="blurb">${esc(scenario.blurb)}</p>
      <div class="panel">
        <p class="mock-player">${esc(scenario.player_name || "Sample Player")}</p>
        <p class="mock-meta">CF · France · Rating 84 · Preview only</p>
        <h3>Honours &amp; awards</h3>
        <p class="honours-subhead">Winner medals</p>
        <p class="sub" style="margin:-4px 0 12px;color:#888;font-size:13px;">
          League titles and cups with the champion club (5+ league apps or 1+ cup appearance that season).
        </p>
        ${renderHonoursHtml(scenario.honours, { emptyMessage: emptyMsg })}
      </div>
    </section>`;
}

function renderSingle(scenarioId) {
  const scenario =
    PLAYER_MEDALS_PREVIEW_SCENARIOS.find((s) => s.id === scenarioId) ||
    PLAYER_MEDALS_PREVIEW_SCENARIOS[0];
  return renderScenarioPanel(scenario);
}

function renderAll() {
  return `<div class="preview-all">${PLAYER_MEDALS_PREVIEW_SCENARIOS.map(renderScenarioPanel).join("")}</div>`;
}

function fillScenarioSelect(select) {
  select.innerHTML = `
    <option value="all">All scenarios (scroll)</option>
    ${PLAYER_MEDALS_PREVIEW_SCENARIOS.map(
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
  if (q && (q === "all" || PLAYER_MEDALS_PREVIEW_SCENARIOS.some((s) => s.id === q))) {
    return q;
  }
  return "multi_club";
}

async function main() {
  await initGlobal();
  await loadClubsMap();

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
