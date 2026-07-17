import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const DEFAULT_FEED_URL =
  "https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-sky-feed";

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

async function loadAutoSettings() {
  const urlEl = document.getElementById("autoUrl");
  const keyEl = document.getElementById("autoKey");
  const enEl = document.getElementById("autoEnabled");
  if (!urlEl) return;

  const { data, error } = await supabase
    .from("gpsl_discord_feed_settings")
    .select("edge_function_url, invoke_key, auto_flush_enabled")
    .eq("id", 1)
    .maybeSingle();

  if (error) {
    setStatus(
      "autoStatus",
      `Auto-post settings unavailable — run gpsl_discord_sky_feed_events_auto.sql (${error.message})`,
      false
    );
    if (!urlEl.value) urlEl.value = DEFAULT_FEED_URL;
    return;
  }

  urlEl.value = data?.edge_function_url || DEFAULT_FEED_URL;
  if (data?.invoke_key) keyEl.placeholder = "•••• saved (enter to replace)";
  enEl.checked = data?.auto_flush_enabled !== false;

  if (data?.edge_function_url && data?.invoke_key && data?.auto_flush_enabled !== false) {
    setStatus("autoStatus", "Auto-post configured and enabled.");
  } else {
    setStatus("autoStatus", "Save URL + invoke key to enable hands-free posting.", false);
  }
}

async function saveAutoSettings() {
  const url = document.getElementById("autoUrl")?.value?.trim() || "";
  const keyInput = document.getElementById("autoKey")?.value?.trim() || "";
  const enabled = !!document.getElementById("autoEnabled")?.checked;

  let key = keyInput;
  if (!key) {
    const { data } = await supabase
      .from("gpsl_discord_feed_settings")
      .select("invoke_key")
      .eq("id", 1)
      .maybeSingle();
    key = data?.invoke_key || "";
  }

  if (!url || !key) {
    setStatus("autoStatus", "URL and service_role key are required.", false);
    return;
  }

  setStatus("autoStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_discord_feed_set_auto", {
    p_edge_function_url: url,
    p_invoke_key: key,
    p_enabled: enabled,
  });

  if (error) {
    setStatus("autoStatus", error.message, false);
    return;
  }

  document.getElementById("autoKey").value = "";
  document.getElementById("autoKey").placeholder = "•••• saved (enter to replace)";
  setStatus(
    "autoStatus",
    data?.ok
      ? `Saved. Auto-flush ${enabled ? "ON" : "OFF"}. Use Test auto-flush to verify.`
      : "Saved."
  );
}

async function testAutoFlush() {
  setStatus("autoStatus", "Testing auto-flush…");
  const { data, error } = await supabase.rpc("admin_discord_feed_flush_now");
  if (error) {
    setStatus(
      "autoStatus",
      `${error.message} — run gpsl_discord_feed_auto_flush_fix.sql`,
      false
    );
    return;
  }
  setStatus(
    "autoStatus",
    data?.hint ||
      `pending ${data?.pending_before ?? "?"} → ${data?.pending_after ?? "?"}`,
    (data?.pending_after ?? 1) === 0
  );
  await loadQueue();
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
  const warn =
    Array.isArray(data?.warnings) && data.warnings.length
      ? ` · ${data.warnings[0]}`
      : "";
  const split =
    data?.posted_results != null || data?.posted_news != null
      ? ` (news ${data?.posted_news ?? 0}, results ${data?.posted_results ?? 0})`
      : "";
  setStatus(
    "newsStatus",
    `Posted ${data?.posted ?? 0} of ${data?.pending ?? 0} pending${split}${errs}${warn}.`
  );
  await loadQueue();
}

async function sendTest(channel = "news") {
  const label = channel === "results" ? "#gpsl-results" : "#gpsl-news";
  setStatus("newsStatus", `Sending test to ${label}…`);
  const { data, error } = await invokeFeed({
    test: true,
    channel: channel === "results" ? "results" : "news",
  });
  if (error) {
    setStatus("newsStatus", error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus("newsStatus", "Unexpected response.", false);
    return;
  }
  if (channel === "results" && data.used_results_webhook === false) {
    setStatus(
      "newsStatus",
      "Test sent, but DISCORD_RESULTS_WEBHOOK_URL is missing — it went to the news webhook. Add the results secret and redeploy.",
      false
    );
    return;
  }
  setStatus("newsStatus", `Test message sent to ${label}.`);
}

document.getElementById("newsPushBtn")?.addEventListener("click", () => {
  pushNews().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("newsTestBtn")?.addEventListener("click", () => {
  sendTest("news").catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("resultsTestBtn")?.addEventListener("click", () => {
  sendTest("results").catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("newsRefreshBtn")?.addEventListener("click", () => {
  loadQueue()
    .then(() => setStatus("newsStatus", "Queue refreshed."))
    .catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("autoSaveBtn")?.addEventListener("click", () => {
  saveAutoSettings().catch((e) => setStatus("autoStatus", e.message || String(e), false));
});
document.getElementById("autoTestBtn")?.addEventListener("click", () => {
  testAutoFlush().catch((e) => setStatus("autoStatus", e.message || String(e), false));
});

initAdminPage()
  .then(async (user) => {
    if (!user) return;
    await loadAutoSettings();
    await loadQueue();
  })
  .catch((e) => setStatus("newsStatus", e.message || String(e), false));
