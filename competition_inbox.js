// Inbox helpers (Phase 3 matchday + owner notifications)

import { normalizeClubKey } from "./competition.js";

/** User-facing inbox filters → message_type sets (null = all). */
export const INBOX_CATEGORY_FILTERS = [
  { id: "all", label: "All" },
  { id: "fixture_management", label: "Fixture management" },
  { id: "auctions", label: "Auctions" },
  { id: "transfers_in", label: "Transfers in" },
  { id: "transfers_out", label: "Transfers out" },
  { id: "other", label: "Other" },
];

const INBOX_CATEGORY_TYPES = {
  fixture_management: new Set([
    "result_submitted",
    "result_to_confirm",
    "result_rejected",
    "result_confirmed",
    "monthly_fixtures",
    "match_time_proposed",
    "match_time_countered",
    "match_time_proposal_sent",
    "match_time_counter_sent",
    "match_time_accepted",
    "match_rescheduled",
    "match_emergency_drop",
    "match_forfeit_applied",
    "match_checkin_open",
    "match_mutual_override_requested",
    "match_mutual_override_applied",
    "intl_result_to_confirm",
    "intl_kickoff_proposal",
  ]),
  auctions: new Set(["draft_scheduled", "special_auction_scheduled"]),
  transfers_in: new Set(["transfer_signed"]),
  transfers_out: new Set(["transfer_sold", "underperformance_transfer"]),
};

const INBOX_TYPED_CATEGORIES = Object.values(INBOX_CATEGORY_TYPES);

export function inboxMessageCategory(messageType) {
  const t = String(messageType || "");
  if (INBOX_CATEGORY_TYPES.fixture_management.has(t)) return "fixture_management";
  if (INBOX_CATEGORY_TYPES.auctions.has(t)) return "auctions";
  if (INBOX_CATEGORY_TYPES.transfers_in.has(t)) return "transfers_in";
  if (INBOX_CATEGORY_TYPES.transfers_out.has(t)) return "transfers_out";
  return "other";
}

export function filterInboxByCategory(messages, categoryId) {
  if (!categoryId || categoryId === "all") return messages || [];
  if (categoryId === "other") {
    return (messages || []).filter((m) => {
      const t = String(m?.message_type || "");
      return !INBOX_TYPED_CATEGORIES.some((set) => set.has(t));
    });
  }
  const set = INBOX_CATEGORY_TYPES[categoryId];
  if (!set) return messages || [];
  return (messages || []).filter((m) => set.has(String(m?.message_type || "")));
}

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
