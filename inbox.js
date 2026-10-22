import { supabase, initGlobal, refreshInboxNavBadge, getAuthUserFast } from "./global.js";
import { rejectFixtureResult, normalizeClubKey } from "./competition.js";
import { loadInboxMessages, INBOX_CATEGORY_FILTERS, filterInboxByCategory } from "./competition_inbox.js?v=20260929-mc";
import { inboxActionForMessage } from "./competition_inbox_actions.js?v=20260929-mc";
import {
  acceptProposal,
  cancelMutualOverride,
  confirmMutualOverride,
} from "./match_scheduling.js";
import {
  downloadIcs,
  downloadIcsEach,
  fixtureKickoffEvent,
  fixtureKickoffFilename,
} from "./calendar_ics.js?v=20261020-ics-teams";

/** Inbox types that announce a settled kick-off time. */
const AGREED_KICKOFF_TYPES = new Set([
  "match_time_accepted",
  "match_mutual_override_applied",
]);

let myClub = { short: null, name: null };
/** @type {Map<string, object>|null} my club's fixtures (club_fixtures_my_club), by id */
let myFixturesById = null;
let myOwnerId = null;
let viewArchived = false;
/** Multi-select category ids. Empty = All. */
let activeCategories = new Set();

function selectedCategoryList() {
  return Array.from(activeCategories);
}

function isCategoryActive(id) {
  if (id === "all") return activeCategories.size === 0;
  return activeCategories.has(id);
}

function syncFilterButtons(el) {
  el.querySelectorAll(".inbox-filter-btn").forEach((b) => {
    b.classList.toggle("active", isCategoryActive(b.dataset.category));
    b.setAttribute("aria-pressed", isCategoryActive(b.dataset.category) ? "true" : "false");
  });
}

function toggleInboxCategory(id) {
  if (id === "all") {
    activeCategories.clear();
    return;
  }
  if (activeCategories.has(id)) {
    activeCategories.delete(id);
  } else {
    activeCategories.add(id);
  }
}

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

async function loadMyFixtures(force = false) {
  if (!myClub.short) return new Map();
  if (myFixturesById && !force) return myFixturesById;
  const { data, error } = await supabase.rpc("club_fixtures_my_club");
  if (error) {
    console.warn("inbox: club_fixtures_my_club failed", error);
    myFixturesById = new Map();
    return myFixturesById;
  }
  myFixturesById = new Map(
    (Array.isArray(data) ? data : []).map((f) => [String(f.id), f])
  );
  return myFixturesById;
}

/** Agreed, unplayed and kick-off not more than 2 hours ago. */
function isUpcomingAgreed(f) {
  if (!f || f.schedule_status !== "agreed" || !f.agreed_kickoff_at) return false;
  if (f.status === "played") return false;
  const t = new Date(f.agreed_kickoff_at).getTime();
  return Number.isFinite(t) && t > Date.now() - 2 * 60 * 60 * 1000;
}

function fixtureKickoffLabel(f) {
  try {
    return new Date(f.agreed_kickoff_at).toLocaleString("en-GB", {
      weekday: "short",
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return "";
  }
}

function fixtureCalendarMeta(f) {
  const home = f?.home_club_name || f?.home_club_short_name;
  const away = f?.away_club_name || f?.away_club_short_name;
  let competitionLabel = "GPSL";
  if (f?.competition_type === "league" && f.matchday != null && f.matchday !== "") {
    competitionLabel = `MD${f.matchday}`;
  } else if (f?.cup_code) {
    competitionLabel = String(f.cup_code);
  } else if (f?.division) {
    competitionLabel = String(f.division);
  }
  return {
    home,
    away,
    competitionLabel,
    matchday: f?.matchday,
    competition_type: f?.competition_type,
  };
}

function fixtureCalendarEvent(f) {
  return fixtureKickoffEvent({
    id: f.id,
    kickoffAt: f.agreed_kickoff_at,
    ...fixtureCalendarMeta(f),
  });
}

async function markFixturesAddedToCalendar(fixtures) {
  for (const f of fixtures) {
    const { error } = await supabase.rpc("club_fixture_calendar_mark_set", {
      p_fixture_id: Number(f.id),
      p_added: true,
    });
    if (error) {
      console.warn("inbox: calendar mark failed", f.id, error);
      continue;
    }
    f.calendar_added = true;
  }
}

function pendingCalendarFixtures() {
  return [...(myFixturesById?.values() || [])]
    .filter((f) => isUpcomingAgreed(f) && !f.calendar_added)
    .sort((a, b) => new Date(a.agreed_kickoff_at) - new Date(b.agreed_kickoff_at));
}

async function addFixturesToCalendar(fixtures, { separateFiles = false } = {}) {
  const list = fixtures.filter(isUpcomingAgreed);
  if (!list.length) {
    setStatus("No upcoming agreed kick-offs to add.", true);
    return false;
  }
  const ok = separateFiles
    ? downloadIcsEach(
        list.map((f) => ({
          filename: fixtureKickoffFilename(fixtureCalendarMeta(f)),
          vevent: fixtureCalendarEvent(f),
        }))
      )
    : list.length === 1
      ? downloadIcs(fixtureKickoffFilename(fixtureCalendarMeta(list[0])), [
          fixtureCalendarEvent(list[0]),
        ])
      : downloadIcs("gpsl-agreed-kickoffs.ics", list.map(fixtureCalendarEvent));
  if (!ok) {
    setStatus("Could not build the calendar file.", true);
    return false;
  }
  await markFixturesAddedToCalendar(list);
  setStatus(
    list.length === 1
      ? "Calendar file downloaded — open it to add the match. Marked as added on My Fixtures."
      : `Calendar file${separateFiles ? "s" : ""} downloaded for ${list.length} matches — marked as added on My Fixtures.`
  );
  renderCalendarCatchup();
  return true;
}

function renderCalendarCatchup() {
  const el = document.getElementById("inboxCalCatchup");
  if (!el) return;
  const pending = viewArchived ? [] : pendingCalendarFixtures();
  if (!pending.length) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }
  const n = pending.length;
  const next = pending[0];
  el.hidden = false;
  el.innerHTML = "";

  const text = document.createElement("span");
  text.className = "cal-text";
  text.textContent =
    `📅 ${n} agreed kick-off${n === 1 ? "" : "s"} not in your calendar yet` +
    ` (next: ${fixtureKickoffLabel(next)}).`;

  const allBtn = document.createElement("button");
  allBtn.type = "button";
  allBtn.className = "button";
  allBtn.style.cssText = "padding:6px 12px;font-size:12px;";
  allBtn.textContent = n === 1 ? "Add to calendar" : `Catch up — add all ${n}`;
  allBtn.onclick = async () => {
    allBtn.disabled = true;
    await addFixturesToCalendar(pending);
    allBtn.disabled = false;
    await renderInbox();
  };

  el.appendChild(text);
  el.appendChild(allBtn);

  if (n > 1) {
    const alt = document.createElement("button");
    alt.type = "button";
    alt.className = "cal-alt";
    alt.textContent = "Outlook? one file per match";
    alt.title = "Outlook on Windows often imports only the first match from a multi-match file";
    alt.onclick = async () => {
      await addFixturesToCalendar(pending, { separateFiles: true });
      await renderInbox();
    };
    el.appendChild(alt);
  }
}

/** "Add to calendar" for an agreed kick-off message (uses the fixture's current time). */
function appendAgreedCalendarAction(actions, msg) {
  if (!AGREED_KICKOFF_TYPES.has(msg.message_type) || !msg.fixture_id) return;
  const f = myFixturesById?.get(String(msg.fixture_id));
  if (!f) return;

  if (!isUpcomingAgreed(f)) {
    const note = document.createElement("span");
    note.className = "inbox-cal-note";
    note.textContent =
      f.status === "played"
        ? "Match played."
        : f.schedule_status !== "agreed"
          ? "Kick-off no longer agreed — check the schedule."
          : "Kick-off has passed.";
    actions.appendChild(note);
    return;
  }

  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = f.calendar_added ? "button secondary" : "button";
  btn.textContent = f.calendar_added ? "📅 Added — download again" : "📅 Add to calendar";
  btn.title = `Kick-off ${fixtureKickoffLabel(f)} (your local time)`;
  btn.onclick = async () => {
    btn.disabled = true;
    const ok = await addFixturesToCalendar([f]);
    btn.disabled = false;
    if (ok) {
      btn.className = "button secondary";
      btn.textContent = "📅 Added — download again";
    }
  };
  actions.appendChild(btn);
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
    btn.className = "inbox-filter-btn" + (isCategoryActive(cat.id) ? " active" : "");
    btn.dataset.category = cat.id;
    btn.textContent = cat.label;
    btn.setAttribute("aria-pressed", isCategoryActive(cat.id) ? "true" : "false");
    btn.title =
      cat.id === "all"
        ? "Show all messages"
        : "Toggle filter (multi-select)";
    btn.onclick = async () => {
      toggleInboxCategory(cat.id);
      syncFilterButtons(el);
      await renderInbox();
    };
    el.appendChild(btn);
  }
  const hint = document.createElement("span");
  hint.className = "filter-hint";
  hint.textContent = "Tip: select multiple filters to combine.";
  el.appendChild(hint);
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

  await loadMyFixtures();
  renderCalendarCatchup();

  const allMessages = await loadInboxMessages(supabase, {
    clubShortName: myClub.short,
    ownerId: myOwnerId,
    archivedOnly: viewArchived,
  });
  const selectedCats = selectedCategoryList();
  const messages = filterInboxByCategory(allMessages, selectedCats);

  if (!messages.length) {
    const filterLabels = selectedCats
      .map((id) => INBOX_CATEGORY_FILTERS.find((c) => c.id === id)?.label || id)
      .join(", ");
    const emptyFilter =
      selectedCats.length > 0 && allMessages.length > 0
        ? `<p class="empty">No messages in ${filterLabels} (${allMessages.length} in ${viewArchived ? "archived" : "inbox"}).</p>`
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
      msg.message_type === "season1_invite" &&
      !msg.read_at
    ) {
      // Resolve live invite state so expired offers cannot be accepted from inbox.
      let s1Live = null;
      try {
        const { data } = await supabase.rpc("owner_season1_invite_get_mine");
        s1Live = data;
      } catch {
        s1Live = null;
      }
      const s1info = s1Live?.season1 || {};
      const s1Expired =
        !s1info.response && Boolean(s1Live?.expired || s1info.deadline_passed);
      const s1Pending = Boolean(s1Live?.has_invite) && !s1Expired;

      if (s1Expired && !s1Pending) {
        const expiredNote = document.createElement("p");
        expiredNote.style.cssText = "color:#f4b183;margin:8px 0 0;font-size:13px";
        expiredNote.textContent = s1info.deadline_label
          ? `This Season 1 invite expired (${s1info.deadline_label}).`
          : "This Season 1 invite has expired.";
        actions.appendChild(expiredNote);
      } else if (s1Pending || s1Live == null) {
        const acceptBtn = document.createElement("button");
        const declineBtn = document.createElement("button");
        acceptBtn.className = "button";
        acceptBtn.textContent = "Accept Season 1";
        declineBtn.className = "button danger";
        declineBtn.textContent = "Decline";
        const respondSeason1 = async (decision) => {
          if (decision === "decline" && !confirm("Decline your Season 1 invite?")) {
            return;
          }
          acceptBtn.disabled = true;
          declineBtn.disabled = true;
          try {
            const { error } = await supabase.rpc("owner_season1_invite_respond", {
              p_decision: decision,
            });
            if (error) throw error;
            setStatus(
              decision === "accept"
                ? "Season 1 invite accepted."
                : "Season 1 invite declined."
            );
            await renderInbox();
            await refreshInboxNavBadge();
          } catch (err) {
            setStatus("❌ " + err.message, true);
            acceptBtn.disabled = false;
            declineBtn.disabled = false;
          }
        };
        acceptBtn.onclick = () => respondSeason1("accept");
        declineBtn.onclick = () => respondSeason1("decline");
        actions.appendChild(acceptBtn);
        actions.appendChild(declineBtn);
      }
    } else if (
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
          myFixturesById = null;
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
          myFixturesById = null;
          await renderInbox();
          await refreshInboxNavBadge();
        } catch (err) {
          setStatus("❌ " + err.message, true);
          confirmMutualBtn.disabled = false;
        }
      };

      const declineMutualBtn = document.createElement("button");
      declineMutualBtn.className = "button secondary";
      declineMutualBtn.textContent = "Decline";
      declineMutualBtn.title =
        "Decline if you did not agree this kick-off on Discord";
      declineMutualBtn.onclick = async () => {
        if (
          !confirm(
            "Decline this Discord lock?\n\nUse this if you did not agree that kick-off. They can propose another time on Schedule."
          )
        ) {
          return;
        }
        declineMutualBtn.disabled = true;
        confirmMutualBtn.disabled = true;
        try {
          const res = await cancelMutualOverride(msg.fixture_id);
          if (!res.ok) {
            setStatus(res.soft ? res.msg : "❌ " + res.msg, !res.soft);
            declineMutualBtn.disabled = false;
            confirmMutualBtn.disabled = false;
            return;
          }
          setStatus(res.msg || "Declined — Discord lock cancelled.");
          myFixturesById = null;
          await renderInbox();
          await refreshInboxNavBadge();
        } catch (err) {
          setStatus("❌ " + err.message, true);
          declineMutualBtn.disabled = false;
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
      actions.appendChild(declineMutualBtn);
      actions.appendChild(scheduleBtn);
    } else if (!viewArchived && !isArchived) {
      appendAgreedCalendarAction(actions, msg);
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
