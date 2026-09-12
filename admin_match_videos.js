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

document.getElementById("refreshLogBtn")?.addEventListener("click", () => {
  refreshLog();
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
refreshLog();
