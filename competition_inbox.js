// Inbox helpers (Phase 3 matchday)

import { normalizeClubKey } from "./competition.js";

function inboxForClub(msg, clubShortName) {
  if (!clubShortName || !msg) return false;
  return (
    normalizeClubKey(msg.recipient_club_short_name) ===
    normalizeClubKey(clubShortName)
  );
}

export async function loadInboxMessages(
  supabase,
  { clubShortName, unreadOnly = false } = {}
) {
  if (!clubShortName) return [];

  let query = supabase
    .from("competition_inbox")
    .select("*")
    .eq("recipient_club_short_name", clubShortName)
    .order("created_at", { ascending: false });

  if (unreadOnly) query = query.is("read_at", null);

  const { data, error } = await query;
  if (error) {
    console.error("loadInboxMessages:", error);
    return [];
  }
  return (data || []).filter((m) => inboxForClub(m, clubShortName));
}

export async function countUnreadInbox(supabase, clubShortName) {
  if (!clubShortName) return 0;

  const { count, error } = await supabase
    .from("competition_inbox")
    .select("id", { count: "exact", head: true })
    .eq("recipient_club_short_name", clubShortName)
    .is("read_at", null);

  if (error) {
    console.error("countUnreadInbox:", error);
    return 0;
  }
  return count || 0;
}

export async function refreshDashboardInbox(supabase, clubShortName) {
  const panel = document.getElementById("inboxPanel");
  const countEl = document.getElementById("inboxUnreadCount");
  if (!panel || !countEl) return;

  const unread = clubShortName ? await countUnreadInbox(supabase, clubShortName) : 0;
  countEl.textContent = String(unread);
  panel.classList.toggle("has-unread", unread > 0);

  panel.onclick = () => {
    window.location.href = "matchday.html#inbox";
  };
}
