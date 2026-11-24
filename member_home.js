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
    const { data: qualifying } = await supabase.rpc("owner_qualifying_state");

    if (self?.is_archived || self?.status === "archived" || archived) {
      main.hidden = true;
      archivedCard.hidden = false;
      await wireRejoinWaitingList(!!self?.has_club);
      return;
    }

    if (
      qualifying?.subject === true &&
      self?.has_club !== true
    ) {
      window.location.assign("qualifying.html");
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

const UNARCHIVE_REVIEW =
  "Your unarchive request is being reviewed. You have been tagged in the news channel and sent a Discord message. Staff will approve or decline it.";

function showRejoinStatus(status, text, isError) {
  if (!status) return;
  status.hidden = false;
  status.className = isError ? "mh-status err" : "mh-status";
  status.textContent = text;
}

async function wireRejoinWaitingList(hasClub) {
  const btn = document.getElementById("mhRejoinWaitingBtn");
  const status = document.getElementById("mhRejoinStatus");
  const hint = document.getElementById("mhRejoinHint");
  if (!btn) return;

  if (hasClub) {
    btn.disabled = true;
    btn.title = "You still have a club linked — contact staff";
    showRejoinStatus(
      status,
      "Your account still has a club. Contact staff before asking to be unarchived.",
      true
    );
    return;
  }

  const { data: mine } = await supabase.rpc("owner_unarchive_request_mine");
  if (mine?.status === "pending") {
    btn.disabled = true;
    btn.textContent = "Unarchive requested";
    if (hint) hint.hidden = true;
    showRejoinStatus(status, UNARCHIVE_REVIEW, false);
    return;
  }
  if (mine?.status === "rejected") {
    showRejoinStatus(
      status,
      "The last request was declined. You can ask again.",
      false
    );
  }

  btn.addEventListener("click", async () => {
    if (
      !confirm(
        "Ask staff to unarchive your account?\n\nYou stay archived until they approve it. You will be tagged in the news channel and sent a Discord message."
      )
    ) {
      return;
    }
    btn.disabled = true;
    showRejoinStatus(status, "Sending your request…", false);

    const { data, error } = await supabase.rpc("owner_unarchive_request");

    if (error || data?.ok === false) {
      btn.disabled = false;
      showRejoinStatus(
        status,
        error?.message || data?.detail || data?.reason || "Could not send the request.",
        true
      );
      return;
    }

    btn.textContent = "Unarchive requested";
    if (hint) hint.hidden = true;
    showRejoinStatus(status, UNARCHIVE_REVIEW, false);
  });
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
