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

function scoreline(row) {
  return `${row.club_left} ${row.score_left} - ${row.score_right} ${row.club_right}`;
}

async function invokeIngest(body = {}) {
  const { data, error } = await supabase.functions.invoke(
    "discord-friendlies-ingest",
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

function renderPending(rows) {
  const wrap = document.getElementById("pendingWrap");
  if (!wrap) return;
  if (!rows?.length) {
    wrap.innerHTML = `<p class="note">No pending scorelines.</p>`;
    return;
  }
  wrap.innerHTML = `
    <table class="friendlies-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Reporter</th>
          <th>Scoreline</th>
          <th>Month</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${escapeHtml(formatWhen(r.posted_at))}</td>
            <td>${escapeHtml(r.reporter_club_short_name)}</td>
            <td><span class="status-pending">${escapeHtml(scoreline(r))}</span></td>
            <td>${escapeHtml(r.gpsl_month || "—")}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function renderConfirmed(rows) {
  const wrap = document.getElementById("confirmedWrap");
  if (!wrap) return;
  if (!rows?.length) {
    wrap.innerHTML = `<p class="note">No confirmed friendlies yet.</p>`;
    return;
  }
  wrap.innerHTML = `
    <table class="friendlies-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Scoreline</th>
          <th>Paid left</th>
          <th>Paid right</th>
          <th>Month</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${escapeHtml(formatWhen(r.confirmed_at))}</td>
            <td><span class="status-matched">${escapeHtml(scoreline(r))}</span></td>
            <td title="${escapeHtml(r.left_skipped_reason || "")}">${escapeHtml(
              formatMoney(r.paid_left)
            )}${
              r.left_skipped_reason
                ? ` <span class="note">(${escapeHtml(r.left_skipped_reason)})</span>`
                : ""
            }</td>
            <td title="${escapeHtml(r.right_skipped_reason || "")}">${escapeHtml(
              formatMoney(r.paid_right)
            )}${
              r.right_skipped_reason
                ? ` <span class="note">(${escapeHtml(r.right_skipped_reason)})</span>`
                : ""
            }</td>
            <td>${escapeHtml(r.gpsl_month || "—")}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function loadOverview() {
  const { data, error } = await supabase.rpc("admin_gpsl_friendlies_overview", {
    p_limit: 50,
  });

  if (error) {
    setStatus(
      "pollStatus",
      `Overview unavailable — run discord_friendlies_gate.sql (${error.message})`,
      false
    );
    document.getElementById("pendingWrap").innerHTML =
      `<p class="note">SQL patch not applied yet.</p>`;
    document.getElementById("confirmedWrap").innerHTML =
      `<p class="note">SQL patch not applied yet.</p>`;
    return;
  }

  const meta = document.getElementById("metaPills");
  if (meta) {
    meta.innerHTML = `
      <span class="pill">Season ${escapeHtml(data.season_id ?? "—")}</span>
      <span class="pill">${escapeHtml(data.gpsl_month_label || data.gpsl_month || "No active month")}</span>
      <span class="pill">Pay ${escapeHtml(formatMoney(data.payout))} each</span>
      <span class="pill">Month cap ${escapeHtml(data.month_cap)} friendlies</span>
      <span class="pill">Season cap ${escapeHtml(formatMoney(data.season_cap))}</span>
    `;
  }

  renderPending(data.pending || []);
  renderConfirmed(data.confirmed || []);
}

async function pollNow() {
  setStatus("pollStatus", "Polling Discord friendlies channel…");
  const { data, error } = await invokeIngest({ limit: 50 });
  if (error) {
    setStatus("pollStatus", error.message, false);
    return;
  }
  setStatus(
    "pollStatus",
    `Scan ${data.scanned || 0} · matched ${data.matched || 0} · pending ${data.pending || 0} · ignored ${data.ignored || 0} · dup ${data.duplicates || 0}`
  );
  await loadOverview();
}

document.getElementById("btnPoll")?.addEventListener("click", () => {
  pollNow().catch((e) => setStatus("pollStatus", e.message || String(e), false));
});
document.getElementById("btnRefresh")?.addEventListener("click", () => {
  loadOverview().catch((e) => setStatus("pollStatus", e.message || String(e), false));
});

initAdminPage({
  page: "admin_discord_friendlies",
  title: "Discord Friendlies",
}).then(() => loadOverview());
