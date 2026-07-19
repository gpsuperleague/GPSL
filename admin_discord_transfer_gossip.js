import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const DEFAULT_URL =
  "https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-transfer-gossip-ingest";

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

async function invokeIngest(body = {}) {
  const { data, error } = await supabase.functions.invoke(
    "discord-transfer-gossip-ingest",
    { body }
  );
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
  if (data?.error) return { data, error: new Error(String(data.error)) };
  return { data, error: null };
}

function renderActive(rows) {
  const wrap = document.getElementById("activeWrap");
  if (!wrap) return;
  if (!rows?.length) {
    wrap.innerHTML = `<p class="note">No active rumours.</p>`;
    return;
  }
  wrap.innerHTML = `
    <table class="gossip-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Source</th>
          <th>Headline</th>
          <th>Expires</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${escapeHtml(formatWhen(r.created_at))}</td>
            <td>${escapeHtml(r.source)} / ${escapeHtml(r.kind)}</td>
            <td>${escapeHtml(r.headline)}</td>
            <td>${escapeHtml(formatWhen(r.expires_at))}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function loadAuto() {
  const urlEl = document.getElementById("autoUrl");
  const keyEl = document.getElementById("autoKey");
  const enEl = document.getElementById("autoEnabled");
  if (!urlEl) return;

  const { data, error } = await supabase
    .from("gpsl_discord_transfer_gossip_settings")
    .select("edge_function_url, invoke_key, auto_poll_enabled")
    .eq("id", 1)
    .maybeSingle();

  if (error) {
    setStatus(
      "autoStatus",
      `Run discord_transfer_gossip_cron.sql (${error.message})`,
      false
    );
    urlEl.value = DEFAULT_URL;
    return;
  }

  urlEl.value = data?.edge_function_url || DEFAULT_URL;
  if (data?.invoke_key) keyEl.placeholder = "•••• saved (enter to replace)";
  enEl.checked = data?.auto_poll_enabled === true;
  setStatus(
    "autoStatus",
    data?.invoke_key && data?.auto_poll_enabled
      ? "Auto-poll ON (every 2 minutes)."
      : "Auto-poll OFF — save URL + service_role key.",
    !!(data?.invoke_key && data?.auto_poll_enabled)
  );
}

async function saveAuto() {
  const url = document.getElementById("autoUrl")?.value?.trim() || DEFAULT_URL;
  const key = document.getElementById("autoKey")?.value?.trim() || null;
  const enabled = !!document.getElementById("autoEnabled")?.checked;

  const { error } = await supabase.rpc("admin_discord_transfer_gossip_set_auto", {
    p_edge_function_url: url,
    p_invoke_key: key,
    p_enabled: enabled,
  });
  if (error) {
    setStatus("autoStatus", error.message, false);
    return;
  }
  document.getElementById("autoKey").value = "";
  await loadAuto();
}

async function loadOverview() {
  const { data, error } = await supabase.rpc("admin_gpsl_transfer_gossip_overview", {
    p_limit: 40,
  });
  if (error) {
    setStatus(
      "pollStatus",
      `Run discord_transfer_gossip.sql (${error.message})`,
      false
    );
    return;
  }
  renderActive(data.active || []);
}

async function pollNow() {
  setStatus("pollStatus", "Polling #gpsl-transfer-gossip…");
  const { data, error } = await invokeIngest({ limit: 50 });
  if (error) {
    setStatus("pollStatus", error.message, false);
    return;
  }
  const lines = [
    `Fetched ${data.messages_fetched ?? "?"} · scan ${data.scanned || 0} · rumours ${data.rumours || 0} · ignored ${data.ignored || 0} · dup ${data.duplicates || 0}`,
  ];
  if (data.channel_id_tail) lines.push(`Channel …${data.channel_id_tail}`);
  if (data.empty_content) lines.push(`Empty content: ${data.empty_content}`);
  if (data.skipped_format) lines.push(`Bad format skipped: ${data.skipped_format}`);
  if (data.hint) lines.push(String(data.hint));
  if (Array.isArray(data.samples) && data.samples.length) {
    lines.push("Samples: " + data.samples.map((s) => `"${s}"`).join(" · "));
  }
  const detail = (Array.isArray(data.results) ? data.results : [])
    .slice(-6)
    .map((r) => `${r.status || "?"}: ${r.headline || r.reason || r.content || ""}`);
  if (detail.length) lines.push(detail.join("\n"));
  setStatus("pollStatus", lines.join("\n"), (data.rumours || 0) > 0);
  await loadOverview();
}

function wireButtons() {
  document.getElementById("btnPoll")?.addEventListener("click", () => {
    pollNow().catch((e) => setStatus("pollStatus", e.message || String(e), false));
  });
  document.getElementById("btnRefresh")?.addEventListener("click", () => {
    loadOverview()
      .then(() => setStatus("pollStatus", "Lists refreshed."))
      .catch((e) => setStatus("pollStatus", e.message || String(e), false));
  });
  document.getElementById("autoSaveBtn")?.addEventListener("click", () => {
    saveAuto().catch((e) => setStatus("autoStatus", e.message || String(e), false));
  });
}

initAdminPage({
  page: "admin_discord_transfer_gossip",
  title: "Transfer Gossip",
}).then(async () => {
  wireButtons();
  await loadAuto();
  await loadOverview();
});
