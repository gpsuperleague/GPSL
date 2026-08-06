/**
 * Admin workflow checklist — intro copy (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260806-checklist-rules";

export function getAdminWorkflowChecklistRules() {
  return {
    title: "How this checklist works",
    lead: "Manual ticks for Admin menu tasks (excludes <b>Testing</b> and <b>Owners</b>). Use it as the season-cycle runbook.",
    cards: [
      {
        heading: "Order of work",
        items: [
          "<b>Season Management</b> — live-season ops (checklist, fines, holidays, etc.).",
          "<b>Close Season</b> — final money &amp; archive on the <b>old</b> year (Close Finances last).",
          "<b>End Of Season</b> — mark complete / summer break.",
          "<b>Create Season — rollover</b> — Create Pre-Season (+ contract tick / expiry money on the <b>new</b> year).",
          "<b>Season Break</b> then <b>Pre-Season</b> — GPDB, prizes, bills, auctions.",
          "<b>Create Season — go live</b> — Start season, league fixtures, cups.",
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
