import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const DEFAULT_URL =
  "https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-match-videos-ingest";

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

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v <= 0) return "—";
  return `₿${v.toLocaleString("en-GB")}`;
}

function renderLog(rows) {
  const wrap = document.getElementById("logWrap");
  if (!wrap) return;
  if (!rows?.length) {
    wrap.innerHTML = `<p class="note">No ingest attempts yet.</p>`;
    return;
  }
  wrap.innerHTML = `
    <table class="mv-table">
      <thead>
        <tr>
          <th>When</th>
          <th>OK</th>
          <th>Filename</th>
          <th>Month</th>
          <th>Fixture</th>
          <th>Side</th>
          <th>Credit</th>
          <th>Reason</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${escapeHtml(formatWhen(r.created_at))}</td>
            <td class="${r.ok ? "ok-yes" : "ok-no"}">${r.ok ? "yes" : "no"}</td>
            <td>${escapeHtml(r.filename || "—")}</td>
            <td>${escapeHtml(r.channel_month || "—")}</td>
            <td>${r.fixture_id != null ? escapeHtml(String(r.fixture_id)) : "—"}</td>
            <td>${escapeHtml(r.side || "—")}</td>
            <td>${escapeHtml(formatMoney(r.credited))}</td>
            <td>${escapeHtml(r.reason || "—")}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function refreshLog() {
  setStatus("logStatus", "Loading…");
  const { data, error } = await supabase.rpc("match_video_admin_recent", {
    p_limit: 80,
  });
  if (error) {
    setStatus("logStatus", error.message || "Failed", false);
    return;
  }
  if (!data?.ok) {
    setStatus("logStatus", data?.reason || "Failed", false);
    return;
  }
  setStatus("logStatus", `${(data.rows || []).length} recent rows`);
  renderLog(data.rows || []);
}

async function invokePoll(body = {}) {
  const { data, error } = await supabase.functions.invoke(
    "discord-match-videos-ingest",
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
  if (data?.error) {
    return { data, error: new Error(String(data.error)) };
  }
  return { data, error: null };
}

async function loadAutoSettings() {
  const urlEl = document.getElementById("autoUrl");
  const enEl = document.getElementById("autoEnabled");
  const keyStatus = document.getElementById("autoKeyStatus");
  if (!urlEl) return;

  const { data, error } = await supabase.rpc("admin_discord_match_videos_get_auto");

  if (error) {
    setStatus(
      "autoStatus",
      `Auto-poll unavailable — run match_video_uploads_cron_20260912.sql (${error.message})`,
      false
    );
    if (!urlEl.value) urlEl.value = DEFAULT_URL;
    if (keyStatus) keyStatus.textContent = "Invoke key: unavailable";
    return;
  }

  urlEl.value = data?.edge_function_url || DEFAULT_URL;
  enEl.checked = data?.auto_poll_enabled === true;
  if (keyStatus) {
    keyStatus.textContent = data?.has_key
      ? "Invoke key: saved on server (copied from Friendlies/News when possible)."
      : "Invoke key: missing — Friendlies/News key not found; paste service_role via SQL or re-save Friendlies auto-poll first.";
    keyStatus.style.color = data?.has_key ? "#9d9" : "#f88";
  }

  if (data?.edge_function_url && data?.has_key && data?.auto_poll_enabled) {
    setStatus("autoStatus", "Auto-poll ON — Discord is checked every 2 minutes.");
  } else {
    setStatus(
      "autoStatus",
      "Auto-poll OFF until URL + invoke key are saved and enabled.",
      false
    );
  }
}

async function saveAutoSettings() {
  const url = document.getElementById("autoUrl")?.value?.trim() || "";
  const enabled = !!document.getElementById("autoEnabled")?.checked;

  const { data, error } = await supabase.rpc("admin_discord_match_videos_set_auto", {
    p_edge_function_url: url || DEFAULT_URL,
    p_invoke_key: null,
    p_enabled: enabled,
  });

  if (error) {
    setStatus(
      "autoStatus",
      error.message?.includes("admin_discord_match_videos")
        ? "Run match_video_uploads_cron_20260912.sql, then save again."
        : error.message,
      false
    );
    return;
  }

  await loadAutoSettings();
  setStatus(
    "autoStatus",
    data?.has_key
      ? enabled
        ? "Saved — auto-poll enabled (every 2 minutes)."
        : "Saved — auto-poll disabled."
      : "Saved URL, but invoke key is still missing (copy from Friendlies settings / News).",
    !!data?.has_key && enabled
  );
}

document.getElementById("refreshLogBtn")?.addEventListener("click", () => {
  refreshLog();
});

document.getElementById("pollNowBtn")?.addEventListener("click", async () => {
  setStatus("pollStatus", "Polling Discord…");
  const { data, error } = await invokePoll({ limit: 40 });
  if (error) {
    setStatus("pollStatus", error.message, false);
    return;
  }
  setStatus(
    "pollStatus",
    `OK — channels ${data?.channels_scanned ?? "?"} · videos seen ${data?.messages_with_videos ?? 0} · matched ${data?.matched ?? 0}` +
      (data?.reason ? `\n${data.reason}` : "")
  );
  refreshLog();
});

document.getElementById("autoSaveBtn")?.addEventListener("click", () => {
  saveAutoSettings();
});

document.getElementById("manualLinkForm")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const fixtureId = Number(document.getElementById("manualFixtureId")?.value);
  const side = document.getElementById("manualSide")?.value || "home";
  const url = String(document.getElementById("manualUrl")?.value || "").trim();
  const credit = Boolean(document.getElementById("manualCredit")?.checked);

  setStatus("linkStatus", "Linking…");
  const { data, error } = await supabase.rpc("match_video_admin_link", {
    p_fixture_id: fixtureId,
    p_side: side,
    p_video_url: url,
    p_credit: credit,
  });
  if (error) {
    setStatus("linkStatus", error.message || "Failed", false);
    return;
  }
  if (!data?.ok) {
    setStatus("linkStatus", data?.reason || "Failed", false);
    return;
  }
  setStatus(
    "linkStatus",
    `Linked ${data.side} for fixture ${data.fixture_id}` +
      (Number(data.credited) > 0
        ? ` · credited ₿${Number(data.credited).toLocaleString("en-GB")}`
        : " · no new credit")
  );
  refreshLog();
});

await initAdminPage({ title: "Match videos" });
loadAutoSettings();
refreshLog();
