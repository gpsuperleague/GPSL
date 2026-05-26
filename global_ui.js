// ===============================
// GLOBAL_UI.JS — Shared UI Helpers
// ===============================

// ===============================
// PESDB CLICK HANDLER
// ===============================
export function applyPESDBRowClicks(tbodyId) {
  const tbody = document.getElementById(tbodyId);
  if (!tbody) return;

  tbody.querySelectorAll("tr").forEach(row => {
    row.style.cursor = "pointer";

    row.addEventListener("click", e => {
      const clickedButton =
        e.target.closest("button") ||
        e.currentTarget.querySelector("button:hover");

      if (
        e.target.closest("select") ||
        clickedButton ||
        e.target.closest(".decision-buttons")
      ) {
        return;
      }

      const id = row.dataset.konamiId;
      if (id) {
        window.open(
          `https://pesdb.net/efootball/?id=${id}`,
          "_blank",
          "noopener"
        );
      }
    });
  });
}

// ===============================
// TIME REMAINING FORMATTER
// ===============================
export function formatTimeRemaining(endTime) {
  const end = new Date(endTime);
  const now = new Date();
  const diff = end - now;

  if (diff <= 0) return "Expired";

  const hours = Math.floor(diff / 3600000);
  const mins = Math.floor((diff % 3600000) / 60000);

  return `${hours}h ${mins}m`;
}

// ===============================
// COUNTDOWN FORMATTER
// ===============================
export function formatCountdown(ms) {
  if (ms <= 0) return "0h 0m 0s";

  const totalSecs = Math.floor(ms / 1000);
  const hours = Math.floor(totalSecs / 3600);
  const mins = Math.floor((totalSecs % 3600) / 60);
  const secs = totalSecs % 60;

  return `${hours}h ${mins}m ${secs}s`;
}
