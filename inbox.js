import { supabase, initGlobal, refreshInboxNavBadge } from "./global.js";
import { rejectFixtureResult } from "./competition.js";
import { loadInboxMessages } from "./competition_inbox.js";
import { inboxActionForMessage } from "./competition_inbox_actions.js";

let myClub = { short: null, name: null };
let myOwnerId = null;

function setStatus(msg, isError = false) {
  const el = document.getElementById("inboxStatus");
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? "#f66" : "#ffcc00";
}

async function markRead(inboxId) {
  const { error } = await supabase.rpc("competition_inbox_mark_read", {
    p_inbox_id: inboxId,
  });
  if (error) throw error;
  await refreshInboxNavBadge();
}

async function rejectSubmission(submissionId) {
  const reason = prompt("Reason for rejection (optional):") || null;
  setStatus("Rejecting…");
  const { error } = await rejectFixtureResult(supabase, submissionId, reason);

  if (error) {
    setStatus("❌ " + error.message, true);
    return;
  }

  setStatus("Result rejected. Submitter notified.");
  await renderInbox();
  await refreshInboxNavBadge();
}

function formatMessageTime(iso) {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleString(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    });
  } catch {
    return iso;
  }
}

function appendMarkReadButton(actions, div, msg, readBtnState) {
  const readBtn = document.createElement("button");
  readBtn.className = "button secondary";
  readBtn.textContent = msg.read_at ? "Read" : "Mark read";
  readBtn.disabled = !!msg.read_at;
  readBtn.onclick = async () => {
    try {
      div.classList.remove("unread");
      readBtn.disabled = true;
      readBtn.textContent = "Read";
      await markRead(msg.id);
    } catch (err) {
      div.classList.add("unread");
      readBtn.disabled = false;
      readBtn.textContent = "Mark read";
      setStatus("❌ " + (err.message || "Could not mark read"), true);
    }
  };
  actions.appendChild(readBtn);
}

async function renderInbox() {
  const list = document.getElementById("inboxList");
  if (!myClub.short && !myOwnerId) {
    list.innerHTML =
      '<p class="empty">Link your club to this account in Supabase (<b>Clubs.owner_id</b>) to receive club notifications, or register as an owner awaiting club auction.</p>';
    return;
  }

  const messages = await loadInboxMessages(supabase, {
    clubShortName: myClub.short,
    ownerId: myOwnerId,
  });

  if (!messages.length) {
    list.innerHTML =
      '<p class="empty">No notifications yet. Results, transfers, fines, nation picks, monthly match previews, and season updates will appear here.</p>';
    return;
  }

  list.innerHTML = "";

  for (const msg of messages) {
    const div = document.createElement("div");
    div.className = "inbox-item" + (msg.read_at ? "" : " unread");

    div.innerHTML = `
      <h3>${msg.title}</h3>
      <p>${msg.body}</p>
      <time>${formatMessageTime(msg.created_at)}</time>
      <div class="inbox-actions"></div>
    `;

    const actions = div.querySelector(".inbox-actions");
    const action = inboxActionForMessage(msg);

    if (
      msg.message_type === "result_to_confirm" &&
      !msg.read_at &&
      myClub.short &&
      (msg.recipient_club_short_name || "").toUpperCase() ===
        (myClub.short || "").toUpperCase()
    ) {
      const confirmBtn = document.createElement("button");
      confirmBtn.className = "button";
      confirmBtn.textContent = "Enter your stats & confirm";
      confirmBtn.onclick = () => {
        window.location = action?.href || "matchday.html";
      };

      const rejectBtn = document.createElement("button");
      rejectBtn.className = "button danger";
      rejectBtn.textContent = "Reject";
      rejectBtn.onclick = () => rejectSubmission(msg.submission_id);

      actions.appendChild(confirmBtn);
      actions.appendChild(rejectBtn);
    } else {
      if (action?.href) {
        const openBtn = document.createElement("button");
        openBtn.className = "button";
        openBtn.textContent = action.label;
        openBtn.onclick = () => {
          window.location = action.href;
        };
        actions.appendChild(openBtn);
      }
      appendMarkReadButton(actions, div, msg);
    }

    list.appendChild(div);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  myOwnerId = user.id;

  const { data: club, error: clubErr } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (clubErr) {
    console.error("Club lookup:", clubErr);
  }

  if (club?.ShortName) {
    myClub = { short: club.ShortName, name: club.Club };

    const { data: regs } = await supabase
      .from("competition_club_season_public")
      .select("club_short_name, club_name, division");

    const key = (myClub.short || "").trim().toUpperCase();
    const reg = (regs || []).find(
      (r) => (r.club_short_name || "").trim().toUpperCase() === key
    );
    if (reg) {
      myClub.short = reg.club_short_name;
      myClub.name = reg.club_name || myClub.name;
    }

    document.getElementById("pageMeta").innerHTML =
      `${myClub.name} — notifications for your club. ` +
      `New owner? Read <a href="learning_gpsl.html">Learning GPSL</a>.`;
  } else {
    document.getElementById("pageMeta").innerHTML =
      `Awaiting club assignment — owner messages appear here. ` +
      `Read <a href="learning_gpsl.html">Learning GPSL</a> while you wait.`;
  }

  await renderInbox();
});
