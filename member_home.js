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
      wireRejoinWaitingList(!!self?.has_club);
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

function wireRejoinWaitingList(hasClub) {
  const btn = document.getElementById("mhRejoinWaitingBtn");
  const status = document.getElementById("mhRejoinStatus");
  if (!btn) return;

  if (hasClub) {
    btn.disabled = true;
    btn.title = "You still have a club linked — contact admin";
    if (status) {
      status.hidden = false;
      status.className = "mh-status err";
      status.textContent =
        "Your account still has a club. Contact admin before rejoining the waiting list.";
    }
    return;
  }

  btn.addEventListener("click", async () => {
    if (
      !confirm(
        "Rejoin the owner waiting list?\n\nYou’ll be added as a returning member and can take part in mid-season vacant club claims or the next club auction."
      )
    ) {
      return;
    }
    btn.disabled = true;
    if (status) {
      status.hidden = false;
      status.className = "mh-status";
      status.textContent = "Rejoining waiting list…";
    }

    const { data, error } = await supabase.rpc(
      "waiting_list_self_unarchive_to_list"
    );

    if (error) {
      btn.disabled = false;
      if (status) {
        status.className = "mh-status err";
        status.textContent = error.message;
      }
      return;
    }

    if (!data?.ok) {
      btn.disabled = false;
      if (status) {
        status.className = "mh-status err";
        status.textContent =
          data?.detail || data?.reason || "Could not rejoin waiting list.";
      }
      return;
    }

    if (status) {
      status.className = "mh-status";
      status.textContent = "You’re back on the waiting list — redirecting…";
    }
    window.location.assign(data.redirect || "waiting_list.html");
  });
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
