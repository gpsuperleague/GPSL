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

import {
  formatDurationMs,
  formatTimeRemainingPlain,
  formatTimeRemainingHtml,
} from "./countdown_display.js";

// ===============================
// TIME REMAINING FORMATTER
// ===============================
export function formatTimeRemaining(endTime) {
  return formatTimeRemainingPlain(endTime);
}

export { formatTimeRemainingHtml };

// ===============================
// COUNTDOWN FORMATTER
// ===============================
export function formatCountdown(ms) {
  return formatDurationMs(ms);
}
// ===============================
// NAV BUILDER
// ===============================
export function buildNav(user) {
  const nav = document.getElementById("nav");
  if (!nav) return;

  const email = user?.email || "";

  // Determine which buttons to show
  const isAdmin = email === "gpsuperleague@gmail.com"; // adjust if needed

  const buttons = [
    { id: "dashboard", label: "Dashboard", href: "dashboard.html" },
    { id: "clubs", label: "Clubs", href: "clubs.html" },
    { id: "squad", label: "Squad", href: "squad.html" },
    { id: "listings", label: "Listings", href: "listings.html" },
  ];

  // Draft Auction button (only if enabled globally)
  if (window.GLOBAL_SETTINGS?.draftAuctionEnabled) {
    buttons.push({
      id: "draftauction",
      label: "Draft Auction",
      href: "draftauction.html"
    });
  }

  // Admin button
  if (isAdmin) {
    buttons.push({
      id: "admin",
      label: "Admin",
      href: "admin.html"
    });
  }

  // Logout button (always last)
  buttons.push({
    id: "logout",
    label: "Logout",
    href: "#",
    onclick: "logoutUser()"
  });

  // Build HTML
  nav.innerHTML = `
    <div class="nav-container">
      ${buttons
        .map(btn => {
          const active = (btn.id === window.CURRENT_PAGE) ? "active-nav" : "";
          const click = btn.onclick ? `onclick="${btn.onclick}"` : "";
          return `<a class="nav-btn ${active}" href="${btn.href}" ${click}>${btn.label}</a>`;
        })
        .join("")}
    </div>
  `;
}
