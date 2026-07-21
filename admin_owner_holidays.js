import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  formatUkDateRange,
  holidayRowToDateInputs,
  holidayStatusLabel,
} from "./owner_holidays.js";

primeAdminPageChrome();

let clubs = [];
let holidays = [];
let amendingId = null;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fillClubSelects() {
  const filter = document.getElementById("holidayClubFilter");
  const book = document.getElementById("bookClubSelect");
  const clubOpts = clubs
    .map(
      (c) =>
        `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(
          c.Club || c.ShortName
        )} (${escapeHtml(c.ShortName)})</option>`
    )
    .join("");

  if (filter) {
    const keep = filter.value;
    filter.innerHTML = `<option value="">All clubs</option>${clubOpts}`;
    filter.value = keep || "";
  }
  if (book) {
    book.innerHTML = `<option value="">— Select —</option>${clubOpts}`;
  }
}

async function loadClubs() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .order("Club");
  if (error) throw error;
  clubs = (data || []).filter((c) => c.ShortName && c.ShortName !== "FOREIGN");
  fillClubSelects();
}

async function refreshHolidays() {
  const body = document.getElementById("holidayAdminBody");
  const club = document.getElementById("holidayClubFilter")?.value || null;

  setStatus("holidayAdminStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_list_club_holidays", {
    p_club_short_name: club || null,
  });

  if (error) {
    setStatus("holidayAdminStatus", error.message, false);
    if (body) {
      body.innerHTML = `<tr><td colspan="6">${escapeHtml(error.message)}</td></tr>`;
    }
    return;
  }

  holidays = data?.holidays || [];
  setStatus(
    "holidayAdminStatus",
    holidays.length
      ? `${holidays.length} booking(s) · max ${data?.max_days ?? 14} days/season`
      : "No holiday bookings for this season."
  );

  if (!body) return;
  if (!holidays.length) {
    body.innerHTML = '<tr><td colspan="6">No holidays found.</td></tr>';
    return;
  }

  body.innerHTML = holidays
    .map((h) => {
      const status = holidayStatusLabel(h);
      const statusClass =
        status === "Active"
          ? "holiday-status holiday-status--active"
          : "holiday-status";
      return `<tr data-id="${h.id}">
        <td>${escapeHtml(h.club_name || h.club_short_name)} <span class="note">(${escapeHtml(
          h.club_short_name
        )})</span></td>
        <td>${escapeHtml(h.owner_tag || "—")}</td>
        <td>${escapeHtml(formatUkDateRange(h.starts_at, h.ends_at))}</td>
        <td>${h.day_count}</td>
        <td><span class="${statusClass}">${escapeHtml(status)}</span></td>
        <td class="holiday-row-actions">
          <button type="button" class="button secondary holiday-admin-amend" data-id="${h.id}">Amend</button>
          <button type="button" class="button danger holiday-admin-cancel" data-id="${h.id}">Remove</button>
        </td>
      </tr>`;
    })
    .join("");

  body.querySelectorAll(".holiday-admin-cancel").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.dataset.id);
      if (!window.confirm("Remove this holiday booking?")) return;
      btn.disabled = true;
      const { error: err } = await supabase.rpc("admin_club_holiday_cancel", {
        p_holiday_id: id,
      });
      btn.disabled = false;
      if (err) {
        setStatus("holidayAdminStatus", err.message, false);
        return;
      }
      if (amendingId === id) closeAmend();
      await refreshHolidays();
    });
  });

  body.querySelectorAll(".holiday-admin-amend").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = Number(btn.dataset.id);
      const row = holidays.find((h) => Number(h.id) === id);
      if (row) openAmend(row);
    });
  });
}

function openAmend(row) {
  amendingId = row.id;
  const card = document.getElementById("holidayAmendCard");
  const meta = document.getElementById("holidayAmendMeta");
  const { startDate, endDate } = holidayRowToDateInputs(row);
  document.getElementById("amendStartDate").value = startDate;
  document.getElementById("amendEndDate").value = endDate;
  if (meta) {
    meta.textContent = `${row.club_name || row.club_short_name} (${row.club_short_name}) · ${holidayStatusLabel(row)}`;
  }
  if (card) card.hidden = false;
  setStatus("amendStatus", "");
  card?.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function closeAmend() {
  amendingId = null;
  const card = document.getElementById("holidayAmendCard");
  if (card) card.hidden = true;
}

function wireAmend() {
  document.getElementById("amendCancelBtn")?.addEventListener("click", closeAmend);
  document.getElementById("amendSaveBtn")?.addEventListener("click", async () => {
    const start = document.getElementById("amendStartDate")?.value;
    const end = document.getElementById("amendEndDate")?.value;
    if (!amendingId || !start || !end) {
      setStatus("amendStatus", "Choose start and end dates.", false);
      return;
    }
    const { error } = await supabase.rpc("admin_club_holiday_amend", {
      p_holiday_id: amendingId,
      p_start_date: start,
      p_end_date: end,
    });
    if (error) {
      setStatus("amendStatus", error.message, false);
      return;
    }
    setStatus("amendStatus", "Holiday amended.");
    closeAmend();
    await refreshHolidays();
  });
}

function wireBook() {
  document.getElementById("bookAdminHolidayBtn")?.addEventListener("click", async () => {
    const club = document.getElementById("bookClubSelect")?.value;
    const start = document.getElementById("bookStartDate")?.value;
    const end = document.getElementById("bookEndDate")?.value;
    if (!club || !start || !end) {
      setStatus("bookAdminStatus", "Club and dates are required.", false);
      return;
    }
    const { error } = await supabase.rpc("admin_club_holiday_book", {
      p_club_short_name: club,
      p_start_date: start,
      p_end_date: end,
    });
    if (error) {
      setStatus("bookAdminStatus", error.message, false);
      return;
    }
    setStatus("bookAdminStatus", "Holiday booked.");
    document.getElementById("bookStartDate").value = "";
    document.getElementById("bookEndDate").value = "";
    await refreshHolidays();
  });
}

async function main() {
  if (!(await initAdminPage())) return;
  await loadClubs();
  document.getElementById("holidayClubFilter")?.addEventListener("change", () => {
    void refreshHolidays();
  });
  document.getElementById("holidayRefreshBtn")?.addEventListener("click", () => {
    void refreshHolidays();
  });
  wireAmend();
  wireBook();
  await refreshHolidays();
}

main().catch((err) => {
  console.error(err);
  setStatus("holidayAdminStatus", err?.message || String(err), false);
});
