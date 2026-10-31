/**
 * Read-only chrome for Discord visitors: banner + hide bid/offer/favourite controls.
 * Server-side writes are already refused (visitors have no club / registry row).
 */
const STYLE_ID = "gpsl-visitor-style";
const BANNER_ID = "gpsl-visitor-banner";

const HIDDEN_SELECTORS = [
  ".bid-panel",
  "#bid-input-section",
  ".make-offer-btn",
  ".club-bid-input-row",
  ".club-bid-inc-row",
  ".club-bid-submit",
  ".club-bid-max-block",
  ".club-bid-warning",
  "#clubBankBalance",
  "#creditsInfo",
  ".fav-btn",
  ".draft-hide-btn",
  ".auction-actions .bid-btn:not(.view-only)",
];

function injectStyle() {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
html.gpsl-visitor ${HIDDEN_SELECTORS.join(",\nhtml.gpsl-visitor ")} {
  display: none !important;
}
#${BANNER_ID} {
  margin: 0 auto 12px;
  max-width: 1100px;
  padding: 10px 14px;
  border: 1px solid #2d4f6b;
  border-radius: 8px;
  background: #13212d;
  color: #cfe6ff;
  font-size: 13px;
  text-align: center;
  line-height: 1.45;
}
#${BANNER_ID} strong { color: #8fd0ff; }
#${BANNER_ID} .visitor-cta-row {
  display: flex; flex-wrap: wrap; gap: 8px; justify-content: center;
  margin-top: 8px;
}
#${BANNER_ID} a.visitor-cta {
  display: inline-block;
  padding: 6px 12px;
  border-radius: 6px;
  font-weight: 700;
  font-size: 13px;
  text-decoration: none;
  background: #ff9900;
  color: #111;
}
#${BANNER_ID} a.visitor-cta.secondary {
  background: #243545;
  color: #cfe6ff;
  border: 1px solid #3a5a75;
}
`;
  document.head.appendChild(style);
}

function injectBanner() {
  if (document.getElementById(BANNER_ID)) return;
  const banner = document.createElement("div");
  banner.id = BANNER_ID;
  banner.innerHTML =
    "<strong>Visitor view — read only.</strong> " +
    "Browsing as a Discord member. Want a club? Apply below — no need to message admin." +
    '<div class="visitor-cta-row">' +
    '<a class="visitor-cta" href="join_gpsl.html">Apply to join the league</a>' +
    '<a class="visitor-cta secondary" href="welcome_gpsl.html">Welcome pack</a>' +
    "</div>";
  const nav = document.getElementById("nav");
  if (nav?.parentNode) {
    nav.parentNode.insertBefore(banner, nav.nextSibling);
  } else {
    document.body.prepend(banner);
  }
}

export function applyVisitorChrome() {
  window.GPSL_VISITOR = true;
  document.documentElement.classList.add("gpsl-visitor");
  injectStyle();
  if (document.body) {
    injectBanner();
  } else {
    document.addEventListener("DOMContentLoaded", injectBanner, { once: true });
  }
}
