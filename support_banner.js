/**
 * Ko-fi + Discord support strip. Supporters see a thank-you instead.
 */
import { discordChatLinkHtml, wireDiscordChatLinks } from "./discord_open.js";

export const KOFI_URL = "https://ko-fi.com/gpsluk";
export const KOFI_DISCORD_CHANNEL_URL =
  "https://discord.com/channels/1483974134361886802/1551895912459280384";
export const KOFI_CUP_SRC = "images/brands/kofi-cup.png";

const DISMISS_KEY = "gpsl_support_banner_hidden_until";
const DISMISS_DAYS = 7;

const STYLE = `
.gpsl-support-banner {
  display: flex; align-items: center; gap: 12px; flex-wrap: wrap;
  margin: 10px 0 14px; padding: 10px 14px; border-radius: 10px;
  background: linear-gradient(90deg, #2a1a12, #1b1f27);
  border: 1px solid rgba(255, 94, 91, 0.35); color: #f2f2f2; font-size: 0.92rem;
}
.gpsl-support-banner img.gpsl-support-cup { width: 34px; height: auto; flex-shrink: 0; }
.gpsl-support-banner .gpsl-support-text { flex: 1 1 260px; line-height: 1.35; }
.gpsl-support-banner .gpsl-support-text strong { color: #ff8a65; }
.gpsl-support-banner .gpsl-support-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.gpsl-support-banner a.gpsl-support-btn,
.gpsl-support-banner a.discord-chat-link {
  display: inline-block; padding: 6px 12px; border-radius: 999px; font-weight: 600;
  text-decoration: none; white-space: nowrap; font-size: 0.88rem;
}
.gpsl-support-banner a.gpsl-support-btn { background: #ff5e5b; color: #fff; }
.gpsl-support-banner a.discord-chat-link { background: #5865f2; color: #fff; }
.gpsl-support-banner button.gpsl-support-close {
  background: none; border: 0; color: #aaa; font-size: 1.1rem; cursor: pointer; padding: 2px 6px;
}
.gpsl-support-banner button.gpsl-support-close:hover { color: #fff; }
`;

function ensureStyle() {
  if (document.getElementById("gpslSupportBannerStyle")) return;
  const s = document.createElement("style");
  s.id = "gpslSupportBannerStyle";
  s.textContent = STYLE;
  document.head.appendChild(s);
}

function isDismissed() {
  const until = Number(localStorage.getItem(DISMISS_KEY) || 0);
  return until > Date.now();
}

/**
 * @param {HTMLElement | null} host
 * @param {{ supporter?: boolean }} [opts]
 */
export function renderSupportBanner(host, opts = {}) {
  if (!host) return;
  if (isDismissed()) {
    host.hidden = true;
    host.innerHTML = "";
    return;
  }
  ensureStyle();
  wireDiscordChatLinks();

  const text = opts.supporter
    ? `<strong>Thanks for supporting GPSL ❤️</strong> Your Ko-fi support keeps the servers on and the league running.`
    : `<strong>Enjoying GPSL?</strong> Ko-fi supporters keep the league running and unlock dashboard colours, a profile badge and the monthly supporter lottery.`;

  host.innerHTML = `
    <div class="gpsl-support-banner" role="complementary" aria-label="Support GPSL">
      <img class="gpsl-support-cup" src="${KOFI_CUP_SRC}" alt="Ko-fi">
      <div class="gpsl-support-text">${text}</div>
      <div class="gpsl-support-actions">
        ${opts.supporter ? "" : `<a class="gpsl-support-btn" href="${KOFI_URL}" target="_blank" rel="noopener noreferrer">Support on Ko-fi</a>`}
        ${discordChatLinkHtml(KOFI_DISCORD_CHANNEL_URL, "Ko-fi channel on Discord")}
      </div>
      <button type="button" class="gpsl-support-close" title="Hide for ${DISMISS_DAYS} days" aria-label="Hide">✕</button>
    </div>`;
  host.hidden = false;

  host.querySelector(".gpsl-support-close")?.addEventListener("click", () => {
    localStorage.setItem(DISMISS_KEY, String(Date.now() + DISMISS_DAYS * 86400000));
    host.hidden = true;
    host.innerHTML = "";
  });
}
