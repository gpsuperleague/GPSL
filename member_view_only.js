/**
 * Waiting-list / no-club members: browse the site view-only + home back to waiting list.
 */

const BAR_ID = "gpslMemberViewOnlyBar";
const STYLE_ID = "gpslMemberViewOnlyStyle";

export function isMemberViewOnlyActive() {
  return window.GPSL_MEMBER_VIEW_ONLY === true;
}

export function applyMemberViewOnlyChrome({ homeHref = "waiting_list.html" } = {}) {
  if (!isMemberViewOnlyActive()) return;

  document.documentElement.classList.add("gpsl-view-only");
  document.body?.classList.add("gpsl-view-only");

  if (!document.getElementById(STYLE_ID)) {
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      body.gpsl-view-only { padding-top: 42px; }
      #${BAR_ID} {
        position: fixed; top: 0; left: 0; right: 0; z-index: 10050;
        display: flex; align-items: center; justify-content: space-between; gap: 12px;
        padding: 8px 14px; background: #1a1510; border-bottom: 1px solid #664400;
        color: #ddd; font-size: 13px; font-family: Arial, sans-serif;
      }
      #${BAR_ID} a {
        color: #ff9900; font-weight: bold; text-decoration: none;
        border: 1px solid #665533; padding: 4px 10px; border-radius: 4px; background: #221a10;
      }
      #${BAR_ID} a:hover { background: #332810; }
      #${BAR_ID} .gpsl-vo-note { color: #bbb; }
      body.gpsl-view-only button.button:not(.gpsl-view-ok),
      body.gpsl-view-only .btn-result,
      body.gpsl-view-only input[type="submit"],
      body.gpsl-view-only button[type="submit"],
      body.gpsl-view-only .btn-bid,
      body.gpsl-view-only .btn-offer,
      body.gpsl-view-only .match-sim-btn,
      body.gpsl-view-only #simulateResultBtn,
      body.gpsl-view-only #instantResultBtn,
      body.gpsl-view-only #submitResultBtn {
        opacity: 0.45; pointer-events: none; cursor: not-allowed;
      }
    `;
    document.head.appendChild(style);
  }

  if (!document.getElementById(BAR_ID)) {
    const bar = document.createElement("div");
    bar.id = BAR_ID;
    bar.innerHTML = `
      <span class="gpsl-vo-note">Waiting list — browse only (no bids, submits, or club actions).</span>
      <a class="gpsl-view-ok" href="${homeHref}">Home · Waiting list</a>
    `;
    document.body.prepend(bar);
  }
}
