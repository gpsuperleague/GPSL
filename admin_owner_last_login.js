import { supabase, initGlobal, getAuthUser } from "./global.js";

function setStatus(elementId, msg, ok = true) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.textContent = msg || "";
  el.className = ok ? "status-line" : "status-line error";
}

/** @type {Array<Record<string, unknown>>} */
let rows = [];
let monthMeta = {
  previousLabel: "Previous month",
  currentLabel: "Current month",
};

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Format elapsed time as weeks, days, hours, minutes. */
function formatTimeSince(iso, nowMs = Date.now()) {
  if (!iso) return { text: "Never", minutes: Number.POSITIVE_INFINITY };

  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return { text: "—", minutes: Number.POSITIVE_INFINITY };

  let mins = Math.floor((nowMs - then) / 60000);
  if (mins < 0) mins = 0;

  const weeks = Math.floor(mins / (7 * 24 * 60));
  const days = Math.floor((mins % (7 * 24 * 60)) / (24 * 60));
  const hours = Math.floor((mins % (24 * 60)) / 60);
  const minutes = mins % 60;

  const parts = [];
  if (weeks) parts.push(`${weeks}w`);
  if (days) parts.push(`${days}d`);
  if (hours) parts.push(`${hours}h`);
  if (minutes || parts.length === 0) parts.push(`${minutes}m`);

  return { text: parts.join(" "), minutes: mins };
}

function formatUkDateTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function ownerLabel(row) {
  const tag = row.owner_tag ? String(row.owner_tag).trim() : "";
  const club = row.club_short_name ? String(row.club_short_name) : "";
  if (tag) return tag;
  if (club) return club;
  return "Owner";
}

function updateMonthHeaders() {
  const prev = document.getElementById("prevMonthCol");
  const cur = document.getElementById("curMonthCol");
  if (prev) {
    prev.textContent = monthMeta.previousLabel
      ? `${monthMeta.previousLabel} logins`
      : "Prev month logins";
  }
  if (cur) {
    cur.textContent = monthMeta.currentLabel
      ? `${monthMeta.currentLabel} logins`
      : "Current month logins";
  }
}

function renderTable(filterText = "") {
  const body = document.getElementById("loginTableBody");
  if (!body) return;

  const q = String(filterText || "")
    .trim()
    .toLowerCase();

  const filtered = !q
    ? rows
    : rows.filter((r) => {
        const hay = [
          r.owner_tag,
          r.club_short_name,
          r.club_name,
          r.registry_status,
        ]
          .map((x) => String(x || "").toLowerCase())
          .join(" ");
        return hay.includes(q);
      });

  if (!filtered.length) {
    body.innerHTML = `<tr><td colspan="8">${
      rows.length ? "No matches." : "No owners found."
    }</td></tr>`;
    return;
  }

  const now = Date.now();
  body.innerHTML = filtered
    .map((r, i) => {
      const since = formatTimeSince(r.last_sign_in_at, now);
      const sinceClass = !r.last_sign_in_at
        ? "never"
        : since.minutes >= 7 * 24 * 60
          ? "stale"
          : "";
      const club = r.club_name
        ? `${escapeHtml(r.club_name)} <span class="muted">(${escapeHtml(
            r.club_short_name
          )})</span>`
        : r.club_short_name
          ? escapeHtml(r.club_short_name)
          : '<span class="muted">—</span>';

      const prevN = Number(r.logins_previous_month) || 0;
      const curN = Number(r.logins_current_month) || 0;

      return `<tr>
        <td class="num">${i + 1}</td>
        <td>${escapeHtml(ownerLabel(r))}</td>
        <td>${club}</td>
        <td>${escapeHtml(r.registry_status || "—")}</td>
        <td>${escapeHtml(formatUkDateTime(r.last_sign_in_at))}</td>
        <td class="num ${sinceClass}">${escapeHtml(since.text)}</td>
        <td class="num">${prevN}</td>
        <td class="num">${curN}</td>
      </tr>`;
    })
    .join("");
}

function parseRpcPayload(data) {
  if (Array.isArray(data)) {
    return {
      owners: data,
      previousLabel: "Previous month",
      currentLabel: "Current month",
    };
  }
  if (data && typeof data === "object") {
    return {
      owners: Array.isArray(data.owners) ? data.owners : [],
      previousLabel: data.previous_gpsl_month_label || "Previous month",
      currentLabel: data.current_gpsl_month_label || "Current month",
    };
  }
  return { owners: [], previousLabel: "Previous month", currentLabel: "Current month" };
}

async function refresh() {
  setStatus("loginStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_owner_last_logins");
  if (error) {
    setStatus("loginStatus", error.message, false);
    rows = [];
    renderTable(document.getElementById("loginSearch")?.value);
    return;
  }

  const parsed = parseRpcPayload(data);
  monthMeta = {
    previousLabel: parsed.previousLabel,
    currentLabel: parsed.currentLabel,
  };
  updateMonthHeaders();

  rows = parsed.owners;
  rows.sort((a, b) => {
    const ta = a.last_sign_in_at ? new Date(a.last_sign_in_at).getTime() : -1;
    const tb = b.last_sign_in_at ? new Date(b.last_sign_in_at).getTime() : -1;
    if (tb !== ta) return tb - ta;
    return String(a.owner_tag || a.club_short_name || "").localeCompare(
      String(b.owner_tag || b.club_short_name || "")
    );
  });

  const monthBits = [
    monthMeta.previousLabel ? `prev ${monthMeta.previousLabel}` : null,
    monthMeta.currentLabel ? `current ${monthMeta.currentLabel}` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  setStatus(
    "loginStatus",
    `${rows.length} owner${rows.length === 1 ? "" : "s"} (archived hidden)${
      monthBits ? ` · ${monthBits}` : ""
    }`
  );
  renderTable(document.getElementById("loginSearch")?.value);
}

async function main() {
  const user = await getAuthUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await initGlobal();

  document.getElementById("loginRefreshBtn")?.addEventListener("click", () => {
    void refresh();
  });
  document.getElementById("loginSearch")?.addEventListener("input", (e) => {
    renderTable(e.target.value);
  });

  await refresh();
}

main().catch((err) => {
  console.error(err);
  setStatus("loginStatus", err?.message || String(err), false);
});
