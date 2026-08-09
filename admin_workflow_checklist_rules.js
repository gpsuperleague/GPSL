/**
 * Admin workflow checklist — intro copy (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260809-season-need";

export function getAdminWorkflowChecklistRules() {
  return {
    title: "How this checklist works",
    lead: "Manual ticks for Admin menu tasks (excludes <b>Testing</b> and <b>Owners</b>). Use it as the season-cycle runbook.",
    cards: [
      {
        heading: "Order of work",
        items: [
          "<b>First Season</b> — day-zero auctions: seed club auction, then club / manager / player draft when required.",
          "<b>Season Break</b> — GPDB, auction exclusions, kits, weather, nation setup / clear assignments.",
          "<b>Create Season</b> — Create Pre-Season (contract tick + ledger), then prize money, divisions, calendar, go live, fixtures, cups.",
          "<b>Pre-Season setup</b> — Next Gen, Homegrown draw, club/stadium/manager, challenges, bills, internationals selection.",
          "<b>Pre-Season (June &amp; July)</b> — transfer window, draft/special auctions, manager renewal deadline before August.",
          "<b>Season Management</b> — live-season ops (club checklist, fines, holidays…).",
          "<b>Season Checklist</b> — month-by-month tasks through Playoffs.",
          "<b>Close Season</b> then <b>End Of Season</b> — wrap the year (Close Finances last on the old season). After End season: finish Season Break setup as needed, then <b>Create Season</b>.",
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
        heading: "Season dependency badges",
        items: [
          "<b>Needs active season</b> — live/current season id (Season Management, monthly checklist, Close Season).",
          "<b>Needs season #</b> — a season row (preseason/setup or closing year), not necessarily live.",
          "<b>Creates season</b> / <b>Activates season</b> / <b>Ends season</b> — Create Pre-Season, Start season (go live), End season.",
          "No badge = global / config / assets (GPDB, kits, weather, auction switches, First Season auctions).",
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
