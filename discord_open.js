/**
 * Prefer Discord desktop/mobile app when installed; fall back to web.
 *
 * Supports admin-stored https invite / channel links (and existing discord://).
 */

/**
 * @param {string} raw
 * @returns {{ web: string, app: string | null } | null}
 */
export function parseDiscordChatUrl(raw) {
  const trimmed = String(raw || "").trim();
  if (!trimmed) return null;

  let web = trimmed;
  let app = null;

  if (/^discord:\/\//i.test(trimmed)) {
    app = trimmed;
    const invite = trimmed.match(/discord:\/\/(?:-\/)?invite\/([A-Za-z0-9-]+)/i);
    if (invite) web = `https://discord.gg/${invite[1]}`;
    const ch = trimmed.match(/discord:\/\/(?:-\/)?channels\/(\d+)\/(\d+)/i);
    if (ch) web = `https://discord.com/channels/${ch[1]}/${ch[2]}`;
    return { web, app };
  }

  try {
    const u = new URL(trimmed);
    const host = u.hostname.replace(/^www\./i, "").toLowerCase();

    if (host === "discord.gg") {
      const code = u.pathname.replace(/^\//, "").split("/")[0];
      if (code) {
        web = `https://discord.gg/${code}`;
        app = `discord://-/invite/${code}`;
      }
    } else if (host === "discord.com" || host === "discordapp.com") {
      const invite = u.pathname.match(/^\/invite\/([A-Za-z0-9-]+)/i);
      if (invite) {
        web = `https://discord.gg/${invite[1]}`;
        app = `discord://-/invite/${invite[1]}`;
      } else {
        const channel = u.pathname.match(/^\/channels\/(\d+)\/(\d+)/);
        if (channel) {
          web = `https://discord.com/channels/${channel[1]}/${channel[2]}`;
          app = `discord://-/channels/${channel[1]}/${channel[2]}`;
        }
      }
    }
  } catch {
    return { web: trimmed, app: null };
  }

  return { web, app };
}

/**
 * Try Discord app first; if focus stays on this page, open https.
 * @param {string} rawUrl
 * @param {MouseEvent} [event]
 */
export function openDiscordPreferApp(rawUrl, event) {
  const parsed = parseDiscordChatUrl(rawUrl);
  if (!parsed) return;

  if (event) {
    event.preventDefault();
    event.stopPropagation();
  }

  const { web, app } = parsed;
  if (!app) {
    window.open(web, "_blank", "noopener,noreferrer");
    return;
  }

  let handedOff = false;
  const markHandedOff = () => {
    handedOff = true;
  };

  window.addEventListener("blur", markHandedOff);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) markHandedOff();
  });

  // Hidden iframe launches the custom protocol without navigating GPSL away.
  const iframe = document.createElement("iframe");
  iframe.style.cssText =
    "display:none;width:0;height:0;border:0;position:absolute";
  iframe.setAttribute("aria-hidden", "true");
  iframe.src = app;
  document.body.appendChild(iframe);

  setTimeout(() => {
    window.removeEventListener("blur", markHandedOff);
    try {
      iframe.remove();
    } catch {
      /* ignore */
    }
    if (!handedOff && !document.hidden) {
      window.open(web, "_blank", "noopener,noreferrer");
    }
  }, 1400);
}

/**
 * @param {string} rawUrl
 * @param {string} [label]
 */
export function discordChatLinkHtml(rawUrl, label = "Open Discord chat") {
  const parsed = parseDiscordChatUrl(rawUrl);
  if (!parsed) return "";
  const web = escapeAttr(parsed.web);
  const app = parsed.app ? escapeAttr(parsed.app) : "";
  return (
    `<a class="discord-chat-link" href="${web}"` +
    (app ? ` data-discord-app="${app}"` : "") +
    ` data-discord-web="${web}"` +
    ` target="_blank" rel="noopener noreferrer">${escapeText(label)}</a>`
  );
}

/** Wire once: clicks on .discord-chat-link prefer the app. */
export function wireDiscordChatLinks(root = document) {
  if (root.__gpslDiscordWired) return;
  root.__gpslDiscordWired = true;
  root.addEventListener("click", (e) => {
    const a = e.target?.closest?.("a.discord-chat-link");
    if (!a) return;
    const web = a.getAttribute("data-discord-web") || a.getAttribute("href");
    if (!web) return;
    openDiscordPreferApp(web, e);
  });
}

function escapeAttr(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

function escapeText(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
