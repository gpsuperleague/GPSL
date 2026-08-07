/**
 * Pre-club owners: sticky note that the menu is limited until they have a club.
 * (Full browse view-only was removed — access is gated to a short allow-list.)
 */

const BAR_ID = "gpslMemberViewOnlyBar";
const STYLE_ID = "gpslMemberViewOnlyStyle";

export function isMemberViewOnlyActive() {
  return window.GPSL_MEMBER_VIEW_ONLY === true || window.GPSL_PRE_CLUB === true;
}

export function applyMemberViewOnlyChrome({ homeHref = "waiting_list.html" } = {}) {
  if (!isMemberViewOnlyActive()) return;

  document.documentElement.classList.add("gpsl-pre-club");
  document.body?.classList.add("gpsl-pre-club");

  if (!document.getElementById(STYLE_ID)) {
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      body.gpsl-pre-club { padding-top: 42px; }
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
      #${BAR_ID} .gpsl-vo-bank { color: #9f9; font-variant-numeric: tabular-nums; white-space: nowrap; }
    `;
    document.head.appendChild(style);
  }

  if (!document.getElementById(BAR_ID)) {
    const bar = document.createElement("div");
    bar.id = BAR_ID;
    bar.innerHTML = `
      <span class="gpsl-vo-note">No club yet — waiting list, databases, owner details, and club draft auction only.</span>
      <span style="display:flex;align-items:center;gap:12px;">
        <span class="gpsl-vo-bank" id="gpslPreClubBank" hidden></span>
        <a class="gpsl-view-ok" href="${homeHref}">Home · Waiting list</a>
      </span>
    `;
    document.body.prepend(bar);
  }

  refreshPreClubBankBadge().catch(() => {});
}

async function refreshPreClubBankBadge() {
  const el = document.getElementById("gpslPreClubBank");
  if (!el) return;
  try {
    const mod = await import("./supabase_client.js");
    const { data: self } = await mod.supabase.rpc("owner_registry_get_self");
    const bal = Number(self?.pending_starting_balance);
    if (!Number.isFinite(bal) || bal <= 0) {
      el.hidden = true;
      return;
    }
    el.hidden = false;
    el.innerHTML = `Bank: <a href="awaiting_club.html" style="color:#9f9;font-weight:bold;border:none;padding:0;background:none;">₿${Math.round(
      bal
    ).toLocaleString("en-GB")}</a>`;
  } catch {
    el.hidden = true;
  }
}
