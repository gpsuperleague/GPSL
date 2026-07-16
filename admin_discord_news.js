import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

async function invokeFeed(body) {
  const { data, error } = await supabase.functions.invoke("discord-sky-feed", { body });
  if (error) {
    let detail = error.message || "Request failed";
    try {
      const ctx = error.context;
      if (ctx && typeof ctx.json === "function") {
        const payload = await ctx.json();
        if (payload?.error) detail = String(payload.error);
      }
    } catch {
      /* ignore */
    }
    if (data?.error) detail = String(data.error);
    return { data, error: new Error(detail) };
  }
  if (data?.error) {
    return { data, error: new Error(String(data.error)) };
  }
  return { data, error: null };
}

async function loadQueue() {
  const { data, error } = await supabase
    .from("gpsl_discord_feed_queue")
    .select("id, event_type, headline, body, status, last_error, created_at, posted_at")
    .order("id", { ascending: false })
    .limit(40);

  const wrap = document.getElementById("newsTableWrap");
  if (error) {
    wrap.innerHTML = `<p class="note">Could not load queue: ${escapeHtml(error.message)}. Run the SQL patch first.</p>`;
    return;
  }

  const rows = data || [];
  if (!rows.length) {
    wrap.innerHTML = `<p class="note">Queue empty — nothing pending yet.</p>`;
    return;
  }

  wrap.innerHTML = `
    <table class="news-table">
      <thead>
        <tr>
          <th>ID</th>
          <th>Type</th>
          <th>Headline</th>
          <th>Status</th>
          <th>Created</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${r.id}</td>
            <td>${escapeHtml(r.event_type)}</td>
            <td>
              <div>${escapeHtml(r.headline)}</div>
              ${r.body ? `<div class="news-body">${escapeHtml(r.body)}</div>` : ""}
              ${r.last_error ? `<div class="news-body" style="color:#f88">${escapeHtml(r.last_error)}</div>` : ""}
            </td>
            <td><span class="news-status ${escapeHtml(r.status)}">${escapeHtml(r.status)}</span></td>
            <td>${escapeHtml(formatWhen(r.created_at))}${
              r.posted_at ? `<div class="news-body">Posted ${escapeHtml(formatWhen(r.posted_at))}</div>` : ""
            }</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function pushNews() {
  setStatus("newsStatus", "Pushing pending items…");
  const { data, error } = await invokeFeed({});
  if (error) {
    setStatus("newsStatus", error.message, false);
    return;
  }
  const errs = Array.isArray(data?.errors) && data.errors.length
    ? ` (${data.errors.length} error${data.errors.length === 1 ? "" : "s"})`
    : "";
  setStatus(
    "newsStatus",
    `Posted ${data?.posted ?? 0} of ${data?.pending ?? 0} pending${errs}.`
  );
  await loadQueue();
}

async function sendTest() {
  setStatus("newsStatus", "Sending test…");
  const { data, error } = await invokeFeed({ test: true });
  if (error) {
    setStatus("newsStatus", error.message, false);
    return;
  }
  setStatus("newsStatus", data?.ok ? "Test message sent to Discord." : "Unexpected response.");
}

document.getElementById("newsPushBtn")?.addEventListener("click", () => {
  pushNews().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("newsTestBtn")?.addEventListener("click", () => {
  sendTest().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("newsRefreshBtn")?.addEventListener("click", () => {
  loadQueue()
    .then(() => setStatus("newsStatus", "Queue refreshed."))
    .catch((e) => setStatus("newsStatus", e.message || String(e), false));
});

initAdminPage()
  .then((user) => {
    if (!user) return;
    return loadQueue();
  })
  .catch((e) => setStatus("newsStatus", e.message || String(e), false));
