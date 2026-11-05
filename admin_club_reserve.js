import {
  initAdminPage,
  primeAdminPageChrome,
  setStatus,
  supabase,
} from "./admin_common.js";

primeAdminPageChrome();

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatUk(ts) {
  if (!ts) return "—";
  try {
    return new Date(ts).toLocaleString("en-GB", {
      timeZone: "Europe/London",
      day: "2-digit",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return String(ts);
  }
}

function patchHint(msg) {
  if (/admin_club_assignment_|schema cache|Could not find/i.test(msg || "")) {
    return " — run supabase/sql/patches/club_assignment_reserve_20261105.sql";
  }
  return "";
}

async function loadVacantForReserve() {
  const sel = document.getElementById("reserveClubSelect");
  if (!sel) return;

  const { data, error } = await supabase.rpc("admin_club_vacant_for_reserve_list");
  if (error || data?.ok === false) {
    sel.innerHTML = `<option value="">Could not load clubs</option>`;
    setStatus(
      "reserveStatus",
      "❌ " + (error?.message || data?.reason || "Load failed") + patchHint(error?.message),
      false
    );
    return;
  }

  const clubs = Array.isArray(data?.clubs) ? data.clubs : [];
  if (!clubs.length) {
    sel.innerHTML = `<option value="">No vacant clubs available</option>`;
    return;
  }

  /** @type {Map<string, typeof clubs>} */
  const groups = new Map();
  for (const c of clubs) {
    const label = c.division_label || "Vacant";
    if (!groups.has(label)) groups.set(label, []);
    groups.get(label).push(c);
  }

  const parts = [`<option value="">Select vacant club…</option>`];
  for (const [label, rows] of groups) {
    parts.push(`<optgroup label="${escapeHtml(label)}">`);
    for (const c of rows) {
      parts.push(
        `<option value="${escapeHtml(c.short_name)}">${escapeHtml(
          c.club_name
        )} (${escapeHtml(c.short_name)})</option>`
      );
    }
    parts.push(`</optgroup>`);
  }
  sel.innerHTML = parts.join("");
}

async function loadReserved() {
  const empty = document.getElementById("reservedEmpty");
  const table = document.getElementById("reservedTable");
  const tbody = document.getElementById("reservedTbody");
  if (!tbody) return;

  const { data, error } = await supabase.rpc("admin_club_assignment_reserved_list");
  if (error || data?.ok === false) {
    if (empty) {
      empty.hidden = false;
      empty.textContent =
        "❌ " + (error?.message || data?.reason || "Load failed") + patchHint(error?.message);
    }
    if (table) table.hidden = true;
    return;
  }

  const clubs = Array.isArray(data?.clubs) ? data.clubs : [];
  if (!clubs.length) {
    if (empty) {
      empty.hidden = false;
      empty.textContent = "None reserved.";
    }
    if (table) table.hidden = true;
    tbody.innerHTML = "";
    return;
  }

  if (empty) empty.hidden = true;
  if (table) table.hidden = false;
  tbody.innerHTML = clubs
    .map((c) => {
      const short = escapeHtml(c.short_name);
      return `<tr>
        <td><b>${escapeHtml(c.club_name)}</b> <span class="pill-res">[${short}]</span></td>
        <td>${escapeHtml(c.reserved_note || "—")}</td>
        <td>${escapeHtml(formatUk(c.reserved_at))}</td>
        <td style="text-align:right;">
          <button type="button" class="button secondary clear-reserve-btn" data-club="${short}">Clear reserve</button>
        </td>
      </tr>`;
    })
    .join("");

  tbody.querySelectorAll(".clear-reserve-btn").forEach((btn) => {
    btn.onclick = () => clearReserve(btn.getAttribute("data-club"));
  });
}

async function setReserve() {
  const short = document.getElementById("reserveClubSelect")?.value?.trim();
  const note = document.getElementById("reserveNote")?.value?.trim() || null;
  if (!short) {
    setStatus("reserveStatus", "Pick a vacant club.", false);
    return;
  }

  if (
    !confirm(
      `Reserve ${short}?\n\nWaiting-list claim and Club assignment cannot give this club an owner until you clear the reserve.`
    )
  ) {
    return;
  }

  setStatus("reserveStatus", "Reserving…");
  const { data, error } = await supabase.rpc("admin_club_assignment_reserve", {
    p_club_short_name: short,
    p_note: note,
  });
  if (error) {
    setStatus(
      "reserveStatus",
      "❌ " + error.message + patchHint(error.message),
      false
    );
    return;
  }

  setStatus(
    "reserveStatus",
    `✅ ${data?.club_name || short} reserved — hidden from assignment until cleared.`,
    true
  );
  const noteEl = document.getElementById("reserveNote");
  if (noteEl) noteEl.value = "";
  await Promise.all([loadVacantForReserve(), loadReserved()]);
}

async function clearReserve(short) {
  if (!short) return;
  if (!confirm(`Clear reserve on ${short}? It can be assigned again.`)) return;

  setStatus("clearReserveStatus", "Clearing…");
  const { data, error } = await supabase.rpc("admin_club_assignment_clear_reserve", {
    p_club_short_name: short,
  });
  if (error) {
    setStatus(
      "clearReserveStatus",
      "❌ " + error.message + patchHint(error.message),
      false
    );
    return;
  }

  setStatus(
    "clearReserveStatus",
    `✅ Reserve cleared on ${data?.club_name || short}.`,
    true
  );
  await Promise.all([loadVacantForReserve(), loadReserved()]);
}

async function boot() {
  if (!(await initAdminPage({ allowMod: false }))) return;
  document.getElementById("reserveBtn")?.addEventListener("click", setReserve);
  await Promise.all([loadVacantForReserve(), loadReserved()]);
}

boot();
