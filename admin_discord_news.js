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

function renderRoutingStatus(data) {
  const el = document.getElementById("routingStatus");
  if (!el) return;
  const newsOk = data?.news_webhook_configured !== false;
  const resultsOk = !!data?.results_webhook_configured;
  const natterOk = !!data?.natter_webhook_configured;
  const notifyOk = !!data?.notifications_webhook_configured;
  const tablesOk = !!data?.tables_webhook_configured;
  el.innerHTML = `
    <div class="${newsOk ? "ok" : "bad"}">#gpsl-news webhook: ${
      newsOk ? "configured" : "missing DISCORD_WEBHOOK_URL"
    }</div>
    <div class="${resultsOk ? "ok" : "bad"}">#gpsl-results webhook: ${
      resultsOk
        ? "configured (DISCORD_RESULTS_WEBHOOK_URL)"
        : "MISSING — set secret + redeploy discord-sky-feed"
    }</div>
    <div class="${natterOk ? "ok" : "bad"}">#gpsl-natter webhook: ${
      natterOk
        ? "configured (DISCORD_NATTER_WEBHOOK_URL)"
        : "MISSING — set secret + redeploy discord-sky-feed"
    }</div>
    <div class="${notifyOk ? "ok" : "bad"}">#gpsl-notifications webhook: ${
      notifyOk
        ? "configured (DISCORD_NOTIFICATIONS_WEBHOOK_URL)"
        : "MISSING — set secret + redeploy discord-sky-feed"
    }</div>
    <div class="${tablesOk ? "ok" : "bad"}">#gpsl-tables webhook: ${
      tablesOk
        ? "configured (DISCORD_TABLES_WEBHOOK_URL)"
        : "MISSING — set secret + redeploy discord-sky-feed"
    }</div>
    ${
      data?.note
        ? `<div class="note" style="margin-top:8px;">${escapeHtml(data.note)}</div>`
        : ""
    }
  `;
}

async function checkRouting() {
  setStatus("newsStatus", "Checking Discord webhook routing…");
  const { data, error } = await invokeFeed({ diagnose: true });
  if (error) {
    setStatus("newsStatus", error.message, false);
    renderRoutingStatus({
      news_webhook_configured: false,
      results_webhook_configured: false,
      natter_webhook_configured: false,
      notifications_webhook_configured: false,
      tables_webhook_configured: false,
      note: error.message,
    });
    return;
  }
  renderRoutingStatus(data);
  const missing = [];
  if (!data?.results_webhook_configured) missing.push("results");
  if (!data?.natter_webhook_configured) missing.push("natter");
  if (!data?.notifications_webhook_configured) missing.push("notifications");
  if (!data?.tables_webhook_configured) missing.push("tables");
  if (missing.length) {
    setStatus(
      "newsStatus",
      `Missing webhook secret(s): ${missing.join(", ")}. Add under Edge Functions → Secrets, then redeploy discord-sky-feed.`,
      false
    );
    return;
  }
  setStatus(
    "newsStatus",
    "Routing OK — news, results, natter, notifications, and tables webhooks are configured."
  );
}

async function pushNews() {
  setStatus("newsStatus", "Pushing pending items…");
  const { data, error } = await invokeFeed({});
  if (error) {
    setStatus("newsStatus", error.message, false);
    return;
  }
  if (
    data?.results_webhook_configured === false ||
    data?.natter_webhook_configured === false ||
    data?.notifications_webhook_configured === false ||
    data?.tables_webhook_configured === false
  ) {
    renderRoutingStatus({
      news_webhook_configured: true,
      results_webhook_configured: !!data?.results_webhook_configured,
      natter_webhook_configured: !!data?.natter_webhook_configured,
      notifications_webhook_configured: !!data?.notifications_webhook_configured,
      tables_webhook_configured: !!data?.tables_webhook_configured,
      note: "Missing channel secrets block those items (they do not fall back to #gpsl-news).",
    });
  }
  const errs = Array.isArray(data?.errors) && data.errors.length
    ? ` (${data.errors.length} error${data.errors.length === 1 ? "" : "s"})`
    : "";
  const warn =
    Array.isArray(data?.warnings) && data.warnings.length
      ? ` · ${data.warnings[0]}`
      : "";
  const split =
    data?.posted_results != null ||
    data?.posted_news != null ||
    data?.posted_natter != null ||
    data?.posted_notifications != null ||
    data?.posted_tables != null
      ? ` (news ${data?.posted_news ?? 0}, results ${data?.posted_results ?? 0}, natter ${data?.posted_natter ?? 0}, notify ${data?.posted_notifications ?? 0}, tables ${data?.posted_tables ?? 0})`
      : "";
  setStatus(
    "newsStatus",
    `Posted ${data?.posted ?? 0} of ${data?.pending ?? 0} pending${split}${errs}${warn}.`
  );
  await loadQueue();
}

async function sendTest(channel = "news") {
  const label =
    channel === "results"
      ? "#gpsl-results"
      : channel === "natter"
        ? "#gpsl-natter"
        : channel === "notifications"
          ? "#gpsl-notifications"
          : channel === "tables"
            ? "#gpsl-tables"
            : "#gpsl-news";
  setStatus("newsStatus", `Sending test to ${label}…`);
  const { data, error } = await invokeFeed({
    test: true,
    channel:
      channel === "results"
        ? "results"
        : channel === "natter"
          ? "natter"
          : channel === "notifications"
            ? "notifications"
            : channel === "tables"
              ? "tables"
              : "news",
  });
  if (error) {
    setStatus("newsStatus", error.message, false);
    if (
      channel === "results" ||
      channel === "natter" ||
      channel === "notifications" ||
      channel === "tables"
    ) {
      renderRoutingStatus({
        news_webhook_configured: true,
        results_webhook_configured: channel !== "results",
        natter_webhook_configured: channel !== "natter",
        notifications_webhook_configured: channel !== "notifications",
        tables_webhook_configured: channel !== "tables",
        note: error.message,
      });
    }
    return;
  }
  if (!data?.ok) {
    setStatus(
      "newsStatus",
      data?.error || "Unexpected response.",
      false
    );
    return;
  }
  setStatus(
    "newsStatus",
    `Test message sent to ${label}. If you do not see it there, the webhook URL is attached to the wrong Discord channel.`
  );
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
document.getElementById("natterTestBtn")?.addEventListener("click", () => {
  sendTest("natter").catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("notificationsTestBtn")?.addEventListener("click", () => {
  sendTest("notifications").catch((e) =>
    setStatus("newsStatus", e.message || String(e), false)
  );
});
document.getElementById("tablesTestBtn")?.addEventListener("click", () => {
  sendTest("tables").catch((e) =>
    setStatus("newsStatus", e.message || String(e), false)
  );
});
document.getElementById("tablesPublishBtn")?.addEventListener("click", () => {
  (async () => {
    setStatus("newsStatus", "Queueing league tables for Discord…");
    const { data, error } = await supabase.rpc(
      "admin_discord_publish_league_tables",
      {
        p_gpsl_month: null,
        p_season_id: null,
      }
    );
    if (error) {
      setStatus(
        "newsStatus",
        error.message.includes("admin_discord_publish_league_tables")
          ? "❌ Run gpsl_discord_league_tables.sql in Supabase first."
          : "❌ " + error.message,
        false
      );
      return;
    }
    if (!data?.ok) {
      setStatus(
        "newsStatus",
        data?.hint || data?.reason || "Publish failed.",
        false
      );
      return;
    }
    setStatus(
      "newsStatus",
      `Queued tables for ${data?.gpsl_month || "month"} (queue #${data?.queue_id}). Pushing…`
    );
    await pushNews();
  })().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("clinchesBtn")?.addEventListener("click", () => {
  (async () => {
    setStatus("newsStatus", "Scanning for mathematical league clinches…");
    const { data, error } = await supabase.rpc(
      "admin_competition_announce_clinches",
      { p_season_id: null }
    );
    if (error) {
      setStatus(
        "newsStatus",
        error.message.includes("admin_competition_announce_clinches")
          ? "❌ Run gpsl_league_clinch_announcements.sql in Supabase first."
          : "❌ " + error.message,
        false
      );
      return;
    }
    const n = data?.new_clinches ?? 0;
    const sample = Array.isArray(data?.announced) && data.announced[0]?.headline
      ? ` First: ${data.announced[0].headline}`
      : "";
    setStatus(
      "newsStatus",
      n
        ? `Announced ${n} new clinch(es).${sample} Pushing Discord queue…`
        : "No new clinches — everything already announced (or nothing locked yet)."
    );
    if (n) await pushNews();
    else await loadQueue();
  })().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("notificationsTickBtn")?.addEventListener("click", () => {
  (async () => {
    setStatus("newsStatus", "Running notifications tick…");
    const { data, error } = await supabase.rpc("admin_discord_notifications_tick_now");
    if (error) {
      setStatus(
        "newsStatus",
        error.message.includes("admin_discord_notifications_tick_now")
          ? "❌ Run gpsl_discord_notifications_channel.sql in Supabase first."
          : "❌ " + error.message,
        false
      );
      return;
    }
    const announced = Array.isArray(data?.announced)
      ? data.announced.join(", ")
      : "none new";
    setStatus(
      "newsStatus",
      `Notifications tick done (${announced}). Push queue if items are pending.`
    );
    await loadQueue();
  })().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("natterRequeueBtn")?.addEventListener("click", () => {
  (async () => {
    setStatus("newsStatus", "Requeueing recent Natter posts…");
    const { data, error } = await supabase.rpc("admin_discord_requeue_natter_posts", {
      p_days: 60,
    });
    if (error) {
      setStatus(
        "newsStatus",
        error.message.includes("admin_discord_requeue_natter_posts")
          ? "❌ Run gpsl_discord_natter_posts.sql in Supabase first."
          : "❌ " + error.message,
        false
      );
      return;
    }
    setStatus(
      "newsStatus",
      `Requeued ${data?.queued_or_reopened ?? 0} Natter(s). Click Push queue to Discord.`
    );
    await loadQueue();
  })().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("rateLimitRetryBtn")?.addEventListener("click", () => {
  (async () => {
    setStatus("newsStatus", "Unsticking posting / reopening 429 errors…");
    const { data, error } = await supabase.rpc("admin_discord_requeue_rate_limited", {
      p_limit: 200,
    });
    if (error) {
      setStatus(
        "newsStatus",
        error.message.includes("admin_discord_requeue_rate_limited")
          ? "❌ Run gpsl_discord_feed_unstick_posting.sql in Supabase first."
          : "❌ " + error.message,
        false
      );
      return;
    }
    const posting = data?.unstuck_posting ?? 0;
    const limited = data?.reopened_rate_limited ?? data?.reopened ?? 0;
    setStatus(
      "newsStatus",
      `Unstuck ${posting} posting + reopened ${limited} rate-limit error(s) (total ${data?.reopened ?? 0}). Push queue slowly if many remain.`
    );
    await loadQueue();
  })().catch((e) => setStatus("newsStatus", e.message || String(e), false));
});
document.getElementById("routingCheckBtn")?.addEventListener("click", () => {
  checkRouting().catch((e) => setStatus("newsStatus", e.message || String(e), false));
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
    await checkRouting();
  })
  .catch((e) => setStatus("newsStatus", e.message || String(e), false));
