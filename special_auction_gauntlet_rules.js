/**
 * Blind Gauntlet — owner-facing rules copy.
 */

export function getBlindGauntletRulesHtml() {
  return `
    <p class="rules-lead">Three timed rounds with secret bids. After Phase&nbsp;1, the top&nbsp;25% advance — highest Phase&nbsp;2 bid wins the prize.</p>
    <ol class="rules-steps">
      <li>
        <strong>Phase 1 · 15 min</strong>
        <span>One secret bid. Not charged yet. Sets your Phase&nbsp;2 floor.</span>
      </li>
      <li>
        <strong>Reveal · 5 min</strong>
        <span>Everyone ranked. Top ~25% advance; bottom ~25% pay the higher fee; the rest are Middle.</span>
      </li>
      <li>
        <strong>Phase 2 · 10 min</strong>
        <span>Advancers place one final secret bid (≥ Phase&nbsp;1). Highest wins.</span>
      </li>
    </ol>
    <div class="rules-fees">
      <div class="rules-fee top">
        <div class="label">Top 25%</div>
        <div class="outcome">Advance free · then <b>₿3m</b> Phase&nbsp;2 entry</div>
      </div>
      <div class="rules-fee middle">
        <div class="label">Middle</div>
        <div class="outcome">Eliminated · pay <b>₿500k</b></div>
      </div>
      <div class="rules-fee bottom">
        <div class="label">Bottom</div>
        <div class="outcome">Eliminated · pay <b>₿1m</b></div>
      </div>
    </div>
    <p class="rules-note">Winner also pays their Phase&nbsp;2 bid amount on top of the ₿3m entry fee.</p>
  `;
}

export function renderBlindGauntletRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("pageMeta") ||
    document.querySelector(".rules-panel");
  if (!root) return;
  root.innerHTML = getBlindGauntletRulesHtml();
}
