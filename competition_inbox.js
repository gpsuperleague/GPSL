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

export async function loadInboxMessages(
  supabase,
  { clubShortName, ownerId, unreadOnly = false, includeArchived = false } = {}
) {
  const orFilter = buildInboxOrFilter(clubShortName, ownerId);
  if (!orFilter) return [];

  let query = supabase
    .from("competition_inbox")
    .select("*")
    .or(orFilter)
    .order("created_at", { ascending: false });

  if (!includeArchived) {
    query = query.is("archived_at", null);
  }
  if (unreadOnly) query = query.is("read_at", null);

  const { data, error } = await query;
  if (error) {
    console.error("loadInboxMessages:", error);
    return [];
  }

  return (data || []).filter(
    (m) => inboxForClub(m, clubShortName) || inboxForOwner(m, ownerId)
  );
}

export async function countUnreadInbox(
  supabase,
  clubShortName,
  ownerId = null
) {
  const orFilter = buildInboxOrFilter(clubShortName, ownerId);
  if (!orFilter) return 0;

  const { count, error } = await supabase
    .from("competition_inbox")
    .select("id", { count: "exact", head: true })
    .or(orFilter)
    .is("read_at", null)
    .is("archived_at", null);

  if (error) {
    console.error("countUnreadInbox:", error);
    return 0;
  }
  return count || 0;
}
