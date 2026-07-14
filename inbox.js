import { supabase, initGlobal, refreshInboxNavBadge, getAuthUserFast } from "./global.js";
import { rejectFixtureResult, normalizeClubKey } from "./competition.js";
import { loadInboxMessages, INBOX_CATEGORY_FILTERS, filterInboxByCategory } from "./competition_inbox.js";
import { inboxActionForMessage } from "./competition_inbox_actions.js";
import { acceptProposal, confirmMutualOverride } from "./match_scheduling.js";

let myClub = { short: null, name: null };
let myOwnerId = null;
let viewArchived = false;
let activeCategory = "all";

function setStatus(msg, isError = false) {
  const el = document.getElementById("inboxStatus");
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? "#f66" : "#ffcc00";
}

function selectedIds() {
  return Array.from(document.querySelectorAll(".inbox-item-check:checked"))
    .map((cb) => Number(cb.dataset.id))
    .filter((id) => Number.isFinite(id));
}

/** Safe to bulk-select for archive: not favourited, not awaiting match confirm/reject. */
function isReadyForArchive(msg) {
  if (msg.archived_at || msg.is_favourite) return false;

  const pendingConfirm =
    msg.message_type === "result_to_confirm" &&
    !msg.read_at &&
    myClub.short &&
    (msg.recipient_club_short_name || "").toUpperCase() ===
      (myClub.short || "").toUpperCase();

  return !pendingConfirm;
}

function readyArchiveCheckboxes() {
  return Array.from(document.querySelectorAll('.inbox-item-check[data-ready-archive="1"]'));
}

function selectAllReadyForArchive() {
  readyArchiveCheckboxes().forEach((cb) => {
    cb.checked = true;
  });
  updateToolbarButtons();
}

function updateToolbarButtons() {
  const checked = selectedIds().length;
  const archiveBtn = document.getElementById("archiveSelectedBtn");
  const restoreBtn = document.getElementById("restoreSelectedBtn");
  const selectAllReadyBtn = document.getElementById("selectAllReadyBtn");
  const readyCount = readyArchiveCheckboxes().length;

  if (selectAllReadyBtn) {
    selectAllReadyBtn.disabled = readyCount === 0 || viewArchived;
    selectAllReadyBtn.textContent = "Select All";
  }
  if (archiveBtn) {
    archiveBtn.disabled = checked === 0 || viewArchived;
    archiveBtn.textContent =
      checked > 0 ? `Archive selected (${checked})` : "Archive selected";
  }
  if (restoreBtn) {
    restoreBtn.disabled = checked === 0 || !viewArchived;
    restoreBtn.textContent =
      checked > 0 ? `Restore selected (${checked})` : "Restore selected";
  }
}

/** Move favourited row up without re-rendering (preserves archive tick boxes). */
function repositionInboxItem(div, isFav) {
  const list = document.getElementById("inboxList");
  if (!list || viewArchived || !div) return;

  if (isFav) {
    const firstNonFav = list.querySelector(".inbox-item:not(.favourite)");
    if (firstNonFav && firstNonFav !== div) {
      list.insertBefore(div, firstNonFav);
    } else if (!list.querySelector(".inbox-item.favourite") || list.firstElementChild !== div) {
      list.prepend(div);
    }
    return;
  }

  const favItems = list.querySelectorAll(".inbox-item.favourite");
  const lastFav = favItems[favItems.length - 1];
  if (lastFav && lastFav !== div) {
    lastFav.after(div);
  }
}

function setArchivedViewMode(on) {
  viewArchived = on;
  const archivedToolbar = document.getElementById("archivedToolbar");
  const markAllBtn = document.getElementById("markAllReadBtn");
  const archiveBtn = document.getElementById("archiveSelectedBtn");
  const selectAllReadyBtn = document.getElementById("selectAllReadyBtn");

  if (archivedToolbar) {
    archivedToolbar.classList.toggle("visible", on);
  }
  if (markAllBtn) markAllBtn.hidden = on;
  if (selectAllReadyBtn) selectAllReadyBtn.hidden = on;
  if (archiveBtn) archiveBtn.hidden = on;
  updateToolbarButtons();
}

async function markRead(inboxId) {
  const { error } = await supabase.rpc("competition_inbox_mark_read", {
    p_inbox_id: inboxId,
  });
  if (error) throw error;
  await refreshInboxNavBadge();
}

async function toggleFavourite(inboxId) {
  const { data, error } = await supabase.rpc("competition_inbox_toggle_favourite", {
    p_inbox_id: inboxId,
  });
  if (error) {
    const hint = error.message?.includes("competition_inbox_toggle_favourite")
      ? " — re-run patches/owner_inbox_archive.sql"
      : "";
    throw new Error((error.message || "Could not update favourite") + hint);
  }
  return data === true;
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
  const ids = selectedIds();
  if (!ids.length) return;
  if (!confirm(`Archive ${ids.length} selected message(s)? They will move to View archived.`)) return;

  setStatus("Archiving…");
  const { data, error } = await supabase.rpc("competition_inbox_archive_messages", {
    p_inbox_ids: ids,
  });

  if (error) {
    setStatus("❌ " + error.message, true);
    return;
  }

  setStatus(`Archived ${data ?? 0} message(s).`);
  await renderInbox();
  await refreshInboxNavBadge();
}

async function restoreSelected() {
  const ids = selectedIds();
  if (!ids.length) return;

  setStatus("Restoring…");
  const { data, error } = await supabase.rpc("competition_inbox_restore_messages", {
    p_inbox_ids: ids,
  });

  if (error) {
    setStatus("❌ " + error.message, true);
    return;
  }

  setStatus(`Restored ${data ?? 0} message(s) to inbox.`);
  await renderInbox();
  await refreshInboxNavBadge();
}

async function restoreAllArchived() {
  if (!confirm("Restore ALL archived messages back to your inbox?")) return;

  setStatus("Restoring…");
  const { data, error } = await supabase.rpc("competition_inbox_restore_all_archived");
  if (error) {
    setStatus("❌ " + error.message, true);
    return;
  }

  setStatus(`Restored ${data ?? 0} message(s) to inbox.`);
  document.getElementById("showArchivedCb").checked = false;
  setArchivedViewMode(false);
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

async function loadScheduleProposalProposers(proposalIds) {
  const ids = [...new Set(proposalIds.filter((id) => Number.isFinite(id) && id > 0))];
  if (!ids.length) return new Map();

  const { data, error } = await supabase
    .from("competition_fixture_schedule_proposal")
    .select("id, proposed_by_club_short_name")
    .in("id", ids);

  if (error) {
    console.warn("inbox: proposal lookup failed", error);
    return new Map();
  }

  return new Map(
    (data || []).map((row) => [Number(row.id), row.proposed_by_club_short_name])
  );
}

function isScheduleProposalRespondent(msg, proposalProposers) {
  if (!msg?.schedule_proposal_id || !myClub.short) return false;
  const proposer = proposalProposers.get(Number(msg.schedule_proposal_id));
  if (!proposer) return true;
  return normalizeClubKey(proposer) !== normalizeClubKey(myClub.short);
}

function scheduleInboxActionLabel(msg, proposalProposers) {
  if (
    (msg.message_type === "match_time_proposed" ||
      msg.message_type === "match_time_countered") &&
    msg.schedule_proposal_id &&
    !isScheduleProposalRespondent(msg, proposalProposers)
  ) {
    return "View schedule";
  }
  return null;
}

function buildInboxFilters() {
  const el = document.getElementById("inboxFilters");
  if (!el || el.dataset.ready === "1") return;
  el.innerHTML = "";
  const label = document.createElement("span");
  label.className = "filter-label";
  label.textContent = "Show:";
  el.appendChild(label);

  for (const cat of INBOX_CATEGORY_FILTERS) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "inbox-filter-btn" + (cat.id === activeCategory ? " active" : "");
    btn.dataset.category = cat.id;
    btn.textContent = cat.label;
    btn.onclick = async () => {
      if (activeCategory === cat.id) return;
      activeCategory = cat.id;
      el.querySelectorAll(".inbox-filter-btn").forEach((b) => {
        b.classList.toggle("active", b.dataset.category === activeCategory);
      });
      await renderInbox();
    };
    el.appendChild(btn);
  }
  el.dataset.ready = "1";
}

async function renderInbox() {
  const list = document.getElementById("inboxList");
  const toolbar = document.getElementById("inboxToolbar");
  const filters = document.getElementById("inboxFilters");

  if (!myClub.short && !myOwnerId) {
    toolbar.hidden = true;
    if (filters) filters.hidden = true;
    list.innerHTML =
      '<p class="empty">Link your club to this account in Supabase (<b>Clubs.owner_id</b>) to receive club notifications, or register as an owner awaiting club auction.</p>';
    return;
  }

  toolbar.hidden = false;
  if (filters) filters.hidden = false;
  buildInboxFilters();
  setArchivedViewMode(viewArchived);

  const allMessages = await loadInboxMessages(supabase, {
    clubShortName: myClub.short,
    ownerId: myOwnerId,
    archivedOnly: viewArchived,
  });
  const messages = filterInboxByCategory(allMessages, activeCategory);

  if (!messages.length) {
    const emptyFilter =
      activeCategory !== "all" && allMessages.length > 0
        ? `<p class="empty">No messages in this filter (${allMessages.length} in ${viewArchived ? "archived" : "inbox"}).</p>`
        : viewArchived
          ? '<p class="empty">No archived messages.</p>'
          : '<p class="empty">No notifications in your inbox. Tick messages and use <b>Archive selected</b> to move them to archived — only then are they hidden.</p>';
    list.innerHTML = emptyFilter;
    updateToolbarButtons();
    return;
  }

  const proposalProposers = await loadScheduleProposalProposers(
    messages
      .filter(
        (m) =>
          m.schedule_proposal_id &&
          (m.message_type === "match_time_proposed" ||
            m.message_type === "match_time_countered")
      )
      .map((m) => Number(m.schedule_proposal_id))
  );

  list.innerHTML = "";

  for (const msg of messages) {
    const div = document.createElement("div");
    const isArchived = !!msg.archived_at;
    const isFav = !!msg.is_favourite;
    div.className =
      "inbox-item" +
      (msg.read_at || isArchived ? "" : " unread") +
      (isArchived ? " archived" : "") +
      (isFav ? " favourite" : "");

    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.className = "inbox-item-check";
    checkbox.dataset.id = String(msg.id);
    checkbox.title = viewArchived ? "Select to restore" : "Select to archive";
    if (!viewArchived && isReadyForArchive(msg)) {
      checkbox.dataset.readyArchive = "1";
    }
    checkbox.addEventListener("change", updateToolbarButtons);

    const body = document.createElement("div");
    body.className = "inbox-item-body";

    const head = document.createElement("div");
    head.className = "inbox-item-head";

    const title = document.createElement("h3");
    title.innerHTML =
      escapeHtml(msg.title) +
      (isArchived ? '<span class="inbox-archived-tag">(archived)</span>' : "");

    const favBtn = document.createElement("button");
    favBtn.type = "button";
    favBtn.className = "inbox-fav-btn" + (isFav ? " on" : "");
    favBtn.title = isFav ? "Remove favourite" : "Favourite — keep at top of inbox";
    favBtn.setAttribute("aria-label", isFav ? "Unfavourite" : "Favourite");
    favBtn.textContent = isFav ? "★" : "☆";
    favBtn.onclick = async () => {
      try {
        const nowFav = await toggleFavourite(msg.id);
        favBtn.classList.toggle("on", nowFav);
        favBtn.textContent = nowFav ? "★" : "☆";
        div.classList.toggle("favourite", nowFav);
        repositionInboxItem(div, nowFav);
        setStatus(nowFav ? "Added to favourites." : "Removed from favourites.");
      } catch (err) {
        setStatus("❌ " + err.message, true);
      }
    };

    head.appendChild(title);
    head.appendChild(favBtn);

    const para = document.createElement("p");
    para.textContent = msg.body;

    const timeEl = document.createElement("time");
    timeEl.textContent = formatMessageTime(msg.created_at);

    const actions = document.createElement("div");
    actions.className = "inbox-actions";

    body.appendChild(head);
    body.appendChild(para);
    body.appendChild(timeEl);
    body.appendChild(actions);

    div.appendChild(checkbox);
    div.appendChild(body);

    const action = inboxActionForMessage(msg);

    if (
      !viewArchived &&
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
    } else if (
      !viewArchived &&
      !isArchived &&
      (msg.message_type === "match_time_proposed" ||
        msg.message_type === "match_time_countered") &&
      !msg.read_at &&
      msg.schedule_proposal_id &&
      myClub.short &&
      (msg.recipient_club_short_name || "").toUpperCase() ===
        (myClub.short || "").toUpperCase() &&
      isScheduleProposalRespondent(msg, proposalProposers)
    ) {
      const acceptBtn = document.createElement("button");
      acceptBtn.className = "button";
      acceptBtn.textContent = "Accept time";
      acceptBtn.onclick = async () => {
        acceptBtn.disabled = true;
        try {
          const res = await acceptProposal(msg.schedule_proposal_id);
          if (!res.ok) {
            setStatus(res.soft ? res.msg : "❌ " + res.msg, !res.soft);
            acceptBtn.disabled = false;
            if (res.soft) await renderInbox();
            return;
          }
          setStatus("Kick-off agreed.");
          await renderInbox();
          await refreshInboxNavBadge();
        } catch (err) {
          setStatus("❌ " + err.message, true);
          acceptBtn.disabled = false;
        }
      };

      const counterBtn = document.createElement("button");
      counterBtn.className = "button secondary";
      counterBtn.textContent = "Counter / schedule";
      counterBtn.onclick = () => {
        const href =
          action?.href ||
          (msg.fixture_id
            ? `fixture_schedule.html?fixture=${msg.fixture_id}`
            : "fixture_schedule.html");
        window.location = href;
      };

      actions.appendChild(acceptBtn);
      actions.appendChild(counterBtn);
    } else if (
      !viewArchived &&
      !isArchived &&
      msg.message_type === "match_mutual_override_requested" &&
      !msg.read_at &&
      msg.fixture_id &&
      myClub.short &&
      (msg.recipient_club_short_name || "").toUpperCase() ===
        (myClub.short || "").toUpperCase()
    ) {
      const confirmMutualBtn = document.createElement("button");
      confirmMutualBtn.className = "button";
      confirmMutualBtn.textContent = "Confirm change";
      confirmMutualBtn.onclick = async () => {
        confirmMutualBtn.disabled = true;
        try {
          const res = await confirmMutualOverride(msg.fixture_id);
          if (!res.ok) {
            setStatus(res.soft ? res.msg : "❌ " + res.msg, !res.soft);
            confirmMutualBtn.disabled = false;
            if (res.soft) await renderInbox();
            return;
          }
          setStatus(res.applied ? "Kick-off updated." : res.msg || "Confirmed.");
          await renderInbox();
          await refreshInboxNavBadge();
        } catch (err) {
          setStatus("❌ " + err.message, true);
          confirmMutualBtn.disabled = false;
        }
      };

      const scheduleBtn = document.createElement("button");
      scheduleBtn.className = "button secondary";
      scheduleBtn.textContent = "Open schedule";
      scheduleBtn.onclick = () => {
        const href =
          action?.href ||
          (msg.fixture_id
            ? `fixture_schedule.html?fixture=${msg.fixture_id}`
            : "fixture_schedule.html");
        window.location = href;
      };

      actions.appendChild(confirmMutualBtn);
      actions.appendChild(scheduleBtn);
    } else if (!viewArchived && !isArchived) {
      if (action?.href) {
        const openBtn = document.createElement("button");
        openBtn.className = "button";
        openBtn.textContent =
          scheduleInboxActionLabel(msg, proposalProposers) || action.label;
        openBtn.onclick = () => {
          window.location = action.href;
        };
        actions.appendChild(openBtn);
      }
      appendMarkReadButton(actions, div, msg);
    }

    list.appendChild(div);
  }

  updateToolbarButtons();
}

function showInboxLoadFailure(err) {
  console.error("inbox init:", err);
  const pageMeta = document.getElementById("pageMeta");
  const list = document.getElementById("inboxList");
  if (pageMeta) {
    pageMeta.innerHTML =
      "Could not reach GPSL servers. Try refreshing in a minute — if it persists, check whether the Supabase project is paused.";
  }
  if (list) {
    list.innerHTML =
      '<p class="empty" style="color:#f88;">Connection failed (often a temporary Supabase timeout). The browser may show a CORS warning; that usually means the API did not respond in time, not a site bug.</p>';
  }
  setStatus("❌ Could not load inbox — refresh to retry.", true);
}

document.addEventListener("DOMContentLoaded", async () => {
  try {
    await initGlobal();

    document.getElementById("markAllReadBtn").onclick = markAllRead;
    document.getElementById("selectAllReadyBtn").onclick = selectAllReadyForArchive;
    document.getElementById("archiveSelectedBtn").onclick = archiveSelected;
    document.getElementById("restoreSelectedBtn").onclick = restoreSelected;
    document.getElementById("restoreAllBtn").onclick = restoreAllArchived;
    document.getElementById("showArchivedCb").onchange = async (e) => {
      viewArchived = e.target.checked;
      setArchivedViewMode(viewArchived);
      await renderInbox();
    };

    const user = await getAuthUserFast();
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
  } catch (err) {
    showInboxLoadFailure(err);
  }
});
