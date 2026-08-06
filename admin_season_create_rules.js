/**
 * Admin Season — Create new season panel (modular rules cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260807-create-season-rules";

export function getAdminSeasonCreateRules() {
  return {
    title: "Create Pre-Season",
    lead: "Creates the next year as <b>preseason</b> (60 clubs) and runs the player contract tick in the same step (plus manager catch-up if End Season skipped it).",
    cards: [
      {
        heading: "What the button does",
        items: [
          "Inserts the new season label and club registrations.",
          "<b>Automatically</b> ticks player contracts (expiry market + FA releases + multi-year decrement).",
          "Catches up <b>manager</b> season-end if that was skipped when ending the prior year.",
          "If a legacy league year is still open, runs <code>rollover_season</code> first.",
        ],
      },
      {
        heading: "Money &amp; tick order",
        items: [
          "Expiry wage bids and FA releases post money to the <b>new</b> season ledger — not the closed year.",
          "Tick order: <b>unrenewed</b> final-year players FA for MV first, then <b>contested</b> bid winners, then multi-year decrement (avoids needless squad overflow).",
          "Run <code>patches/contract_expiry_rollover_new_season_ledger.sql</code> before the first rollover of a cycle.",
          "Also keep <code>season_contract_tick_catchup.sql</code> + <code>season_rollover_auto_contracts.sql</code> current.",
          "If overflow / assign errors appear: <code>player_assign_to_club_overload_fix.sql</code>, <code>foreign_lock_preseason_fallback.sql</code>, <code>contract_tick_fa_before_contested.sql</code>.",
        ],
      },
      {
        heading: "Timeouts &amp; catch-up",
        items: [
          "Large markets can time out in the browser — the season row may already exist.",
          "Use <b>Tick contracts only</b>, or in SQL Editor: <code>SELECT public.admin_catchup_player_contract_tick();</code>",
          "Optional audit: run <code>admin_expiry_bid_rollover_audit.sql</code> before and after the tick.",
        ],
      },
      {
        heading: "Start season (go live)",
        items: [
          "Use <b>Start season</b> only after Super League + Championship A/B (20+20+20) and the GPSL calendar are set.",
          "Also listed under <b>Admin → Create Season → Start season (go live)</b>.",
          "League / cup fixtures are generated <b>after</b> go live.",
          "After Start, the pre-season dropdown empties — check <b>Live season</b>; that is expected.",
        ],
      },
    ],
  };
}

export function renderAdminSeasonCreateRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("compCreateRules") ||
    document.querySelector(".comp-create-rules");
  renderRulesPanel(root, getAdminSeasonCreateRules());
}
