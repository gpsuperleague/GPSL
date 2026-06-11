// Inbox helpers (Phase 3 matchday + owner notifications)

import { normalizeClubKey } from "./competition.js";

function inboxForClub(msg, clubShortName) {
  if (!clubShortName || !msg) return false;
  return (
    normalizeClubKey(msg.recipient_club_short_name) ===
    normalizeClubKey(clubShortName)
  );
}

function inboxForOwner(msg, ownerId) {
  if (!ownerId || !msg?.owner_id) return false;
  return String(msg.owner_id) === String(ownerId);
}

function buildInboxOrFilter(clubShortName, ownerId) {
  const parts = [];
  if (clubShortName) {
    parts.push(`recipient_club_short_name.eq.${clubShortName}`);
  }
  if (ownerId) {
    parts.push(`owner_id.eq.${ownerId}`);
  }
  return parts.length ? parts.join(",") : null;
}

function isArchived(msg) {
  return msg?.archived_at != null && msg.archived_at !== "";
}

export function sortInboxMessages(messages) {
  return [...messages].sort((a, b) => {
    const favDiff = (b.is_favourite ? 1 : 0) - (a.is_favourite ? 1 : 0);
    if (favDiff !== 0) return favDiff;
    return new Date(b.created_at).getTime() - new Date(a.created_at).getTime();
  });
}

function filterInboxMessages(messages, { includeArchived = false, archivedOnly = false, unreadOnly = false } = {}) {
  let rows = messages;

  if (archivedOnly) {
    rows = rows.filter((m) => isArchived(m));
  } else if (!includeArchived) {
    rows = rows.filter((m) => !isArchived(m));
  }

  if (unreadOnly) {
    rows = rows.filter((m) => !m.read_at && !isArchived(m));
  }

  return sortInboxMessages(rows);
}

export async function loadInboxMessages(
  supabase,
  { clubShortName, ownerId, unreadOnly = false, includeArchived = false, archivedOnly = false } = {}
) {
  const orFilter = buildInboxOrFilter(clubShortName, ownerId);
  if (!orFilter) return [];

  const { data, error } = await supabase
    .from("competition_inbox")
    .select("*")
    .or(orFilter)
    .order("created_at", { ascending: false });

  if (error) {
    console.error("loadInboxMessages:", error);
    return [];
  }

  const owned = (data || []).filter(
    (m) => inboxForClub(m, clubShortName) || inboxForOwner(m, ownerId)
  );

  return filterInboxMessages(owned, { includeArchived, archivedOnly, unreadOnly });
}

export async function countUnreadInbox(
  supabase,
  clubShortName,
  ownerId = null
) {
  const messages = await loadInboxMessages(supabase, {
    clubShortName,
    ownerId,
    unreadOnly: true,
  });
  return messages.length;
}
