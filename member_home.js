import { supabase } from "./supabase_client.js";
import { loadWaitingListPublic } from "./waiting_list.js";

export async function initMemberHomePage() {
  const params = new URLSearchParams(window.location.search);
  const archived = params.get("archived") === "1";

  const main = document.getElementById("mhMain");
  const archivedCard = document.getElementById("mhArchived");
  const posBlock = document.getElementById("mhPositionBlock");
  const posEl = document.getElementById("mhPos");
  const posHint = document.getElementById("mhPosHint");
  const intro = document.getElementById("mhIntro");

  try {
    const { data: self } = await supabase.rpc("owner_registry_get_self");

    if (self?.is_archived || archived) {
      main.hidden = true;
      archivedCard.hidden = false;
      return;
    }

    if (self?.needs_club_auction) {
      window.location.assign("awaiting_club.html");
      return;
    }

    if (self?.has_club) {
      window.location.assign("dashboard.html");
      return;
    }

    const tag = (self?.owner_tag || "").trim();
    if (tag) {
      intro.innerHTML = `You are a <strong>member</strong> (<span style="color:#ccc">${escapeHtml(tag)}</span>) on the owner waiting list. Browse league info and transfers while you wait for a club.`;
    }

    if (self?.is_member) {
      const list = await loadWaitingListPublic();
      if (list?.my_position) {
        posBlock.hidden = false;
        posEl.textContent = `#${list.my_position} of ${list.total || "—"}`;
        posHint.textContent =
          list.my_position === 1
            ? "You are next when admin offers a club slot."
            : `${list.my_position - 1} ahead of you on the list.`;
      }
    }
  } catch (err) {
    console.error(err);
  }
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
