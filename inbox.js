import { supabase, initGlobal, refreshInboxNavBadge } from "./global.js";
import { rejectFixtureResult } from "./competition.js";
import { loadInboxMessages } from "./competition_inbox.js";
import { inboxActionForMessage } from "./competition_inbox_actions.js";

let myClub = { short: null, name: null };
let myOwnerId = null;
let showArchived = false;

function setStatus(msg, isError = false) {
  const el = document.getElementById("inboxStatus");
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? "#f66" : "#ffcc00";
}

function updateArchiveButtonState() {
  const btn = document.getElementById("archiveSelectedBtn");
  if (!btn) return;
  const checked = document.querySelectorAll(".inbox-item-check:checked").length;
  btn.disabled = checked === 0;
  btn.textContent =
    checked > 0 ? `Archive selected (${checked})` : "Archive selected";
}

async function markRead(inboxId) {
  const { error } = await supabase.rpc("competition_inbox_mark_read", {
    p_inbox_id: inboxId,
  });
  if (error) throw error;
  await refreshInboxNavBadge();
}

async function markAllRead() {
  setStatus("Marking all as read…");
  const { data, error } = await supabase.rpc("competition_inbox_mark_all_read");
  if (error) {
    setStatus("❌ " + error.message, true);
    return;
  }
  setStatus(`Marked ${data ?? 0} message(s) as read.`);
  await renderInbox();
  await refreshInboxNavBadge();
}

async function archiveSelected() {
  const ids = Array.from(document.querySelectorAll(".inbox-item-check:checked"))
    .map((cb) => Number(cb.dataset.id))
    .filter((id) => Number.isFinite(id));

  if (!ids.length) return;
  if (!confirm(`Archive ${ids.length} selected message(s)?`)) return;

  setStatus("Archiving…");
  const { data, error } = await supabase.rpc("competition_inbox_archive_messages", {
    p_inbox_ids: ids,
  });

  if (error) {
    const hint = error.message?.includes("competition_inbox_archive_messages")
      ? " — run patches/owner_inbox_archive.sql in Supabase"
      : "";
    setStatus("❌ " + error.message + hint, true);
    return;
  }

  setStatus(`Archived ${data ?? 0} message(s).`);
  await renderInbox();
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

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function appendMarkReadButton(actions, div, msg) {
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
  const toolbar = document.getElementById("inboxToolbar");

  if (!myClub.short && !myOwnerId) {
    toolbar.hidden = true;
    list.innerHTML =
      '<p class="empty">Link your club to this account in Supabase (<b>Clubs.owner_id</b>) to receive club notifications, or register as an owner awaiting club auction.</p>';
    return;
  }

  toolbar.hidden = false;

  const messages = await loadInboxMessages(supabase, {
    clubShortName: myClub.short,
    ownerId: myOwnerId,
    includeArchived: showArchived,
  });

  if (!messages.length) {
    list.innerHTML = showArchived
      ? '<p class="empty">No messages (including archived).</p>'
      : '<p class="empty">No notifications. Archived messages are hidden — tick <b>Show archived</b> to view them.</p>';
    updateArchiveButtonState();
    return;
  }

  list.innerHTML = "";

  for (const msg of messages) {
    const div = document.createElement("div");
    const isArchived = !!msg.archived_at;
    div.className =
      "inbox-item" +
      (msg.read_at || isArchived ? "" : " unread") +
      (isArchived ? " archived" : "");

    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.className = "inbox-item-check";
    checkbox.dataset.id = String(msg.id);
    checkbox.disabled = isArchived;
    checkbox.title = isArchived ? "Already archived" : "Select to archive";
    checkbox.addEventListener("change", updateArchiveButtonState);

    const body = document.createElement("div");
    body.className = "inbox-item-body";
    body.innerHTML = `
      <h3>${escapeHtml(msg.title)}${
        isArchived ? '<span class="inbox-archived-tag">(archived)</span>' : ""
      }</h3>
      <p>${escapeHtml(msg.body)}</p>
      <time>${formatMessageTime(msg.created_at)}</time>
      <div class="inbox-actions"></div>
    `;

    div.appendChild(checkbox);
    div.appendChild(body);

    const actions = body.querySelector(".inbox-actions");
    const action = inboxActionForMessage(msg);

    if (
      !isArchived &&
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
    } else if (!isArchived) {
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

  updateArchiveButtonState();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  document.getElementById("markAllReadBtn").onclick = markAllRead;
  document.getElementById("archiveSelectedBtn").onclick = archiveSelected;
  document.getElementById("showArchivedCb").onchange = async (e) => {
    showArchived = e.target.checked;
    await renderInbox();
  };

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
