/**
 * Admin workflow checklist — intro copy (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260806-checklist-sb-first";

export function getAdminWorkflowChecklistRules() {
  return {
    title: "How this checklist works",
    lead: "Manual ticks for Admin menu tasks (excludes <b>Testing</b> and <b>Owners</b>). Use it as the season-cycle runbook.",
    cards: [
      {
        heading: "Order of work",
        items: [
          "<b>Season Break</b> — GPDB, kits, prizes, internationals, etc. (after the old year is ended).",
          "<b>Create Season</b> — Pre-Season record, divisions, calendar, go live, fixtures, cups.",
          "<b>Pre-Season (June &amp; July)</b> — challenges, bills, auctions, transfers.",
          "<b>Season Management</b> — live-season ops (club checklist, fines, holidays…).",
          "<b>Season Checklist</b> — month-by-month tasks through Playoffs.",
          "<b>Close Season</b> then <b>End Of Season</b> — wrap the year (Close Finances last on the old season).",
        ],
      },
      {
        heading: "Which season is bound",
        items: [
          "While a season is <b>current</b>, ticks bind to that season.",
          "After <b>End season → Summer Break</b>, the list follows the next <b>preseason/setup</b> season (blank) so finished-year ticks are not reused.",
          "Use <b>Clear all ticks</b> to reset the season shown in the summary above.",
        ],
      },
      {
        heading: "Shared vs browser storage",
        items: [
          "<b>Shared</b> = saved in Supabase for all admins (run <code>supabase/sql/patches/admin_workflow_checklist.sql</code> once).",
          "<b>Browser-only</b> = this device until shared storage is available.",
          "Browser ticks are imported automatically the first time shared storage works.",
          "Check the status line under the list for the current mode.",
        ],
      },
    ],
  };
}

export function renderAdminWorkflowChecklistRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("wfRules") ||
    document.querySelector(".wf-rules");
  renderRulesPanel(root, getAdminWorkflowChecklistRules());
}
