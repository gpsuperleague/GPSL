// Inbox helpers (Phase 3 matchday)

export async function loadInboxMessages(supabase, { unreadOnly = false } = {}) {
  let query = supabase
    .from("competition_inbox")
    .select("*")
    .order("created_at", { ascending: false });

  if (unreadOnly) query = query.is("read_at", null);

  const { data, error } = await query;
  if (error) {
    console.error("loadInboxMessages:", error);
    return [];
  }
  return data || [];
}

export async function countUnreadInbox(supabase) {
  const { count, error } = await supabase
    .from("competition_inbox")
    .select("id", { count: "exact", head: true })
    .is("read_at", null);

  if (error) {
    console.error("countUnreadInbox:", error);
    return 0;
  }
  return count || 0;
}

export async function refreshDashboardInbox(supabase) {
  const panel = document.getElementById("inboxPanel");
  const countEl = document.getElementById("inboxUnreadCount");
  if (!panel || !countEl) return;

  const unread = await countUnreadInbox(supabase);
  countEl.textContent = String(unread);
  panel.classList.toggle("has-unread", unread > 0);

  panel.onclick = () => {
    window.location.href = "matchday.html#inbox";
  };
}
