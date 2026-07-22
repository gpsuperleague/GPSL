/** Default action links when competition_inbox.action_href is not set. */

export const INBOX_ACTION_DEFAULTS = {
  welcome_gpsl: { label: "Learning GPSL", href: "learning_gpsl.html" },
  result_submitted: { label: "Match Day", href: "matchday.html" },
  result_to_confirm: { label: "Confirm result", href: "matchday.html" },
  result_confirmed: { label: "Fixtures", href: "fixtures.html" },
  result_rejected: { label: "Re-submit result", href: "matchday.html" },
  transfer_signed: { label: "Squad", href: "squad.html" },
  transfer_sold: { label: "Finances", href: "finances.html" },
  transfer_upcoming: { label: "Transfer Centre", href: "transfer_center.html" },
  draft_scheduled: { label: "Draft auction", href: "draftauction.html" },
  fine_applied: { label: "Finances", href: "finances.html" },
  admin_cash_injection: { label: "Finances", href: "finances.html" },
  admin_emergency_tax: { label: "Finances", href: "finances.html" },
  club_checklist_issues: { label: "Squad", href: "squad.html" },
  loan_drawdown: { label: "League loans", href: "central_bank_loans.html" },
  loan_repayment: { label: "Service counter", href: "central_bank_counter.html" },
  loan_interest: { label: "Service counter", href: "central_bank_counter.html" },
  points_deduction: { label: "League table", href: "progress.html" },
  nation_pick_turn: { label: "Pick nation", href: "nation_select.html" },
  nation_selection_open: { label: "Nation selection", href: "nation_select.html" },
  season_expectations: { label: "Stadium", href: "stadium.html" },
  season_overview: { label: "Club history", href: "history.html" },
  player_awards: { label: "Club history", href: "history.html" },
  monthly_fixtures: { label: "Fixtures", href: "fixtures.html" },
  match_time_proposed: { label: "Schedule match", href: "fixture_schedule.html" },
  match_time_countered: { label: "Respond to proposal", href: "fixture_schedule.html" },
  match_time_proposal_sent: { label: "View schedule", href: "fixture_schedule.html" },
  match_time_counter_sent: { label: "View schedule", href: "fixture_schedule.html" },
  match_time_accepted: { label: "View schedule", href: "fixture_schedule.html" },
  match_rescheduled: { label: "Reschedule match", href: "fixture_schedule.html" },
  match_emergency_drop: { label: "Reschedule match", href: "fixture_schedule.html" },
  match_forfeit_applied: { label: "View fixture", href: "fixture_schedule.html" },
  match_mutual_override_requested: { label: "Confirm kick-off change", href: "fixture_schedule.html" },
  match_mutual_override_applied: { label: "View schedule", href: "fixture_schedule.html" },
};

export function inboxActionForMessage(msg) {
  if (!msg) return null;
  if (msg.action_href) {
    const defaults = INBOX_ACTION_DEFAULTS[msg.message_type];
    let label = defaults?.label || "Open";
    if (msg.action_href.includes("manager_draftauction")) {
      label = "Manager draft";
    } else if (msg.message_type === "draft_scheduled") {
      label = "Player draft";
    }
    return {
      label,
      href: msg.action_href,
    };
  }
  const def = INBOX_ACTION_DEFAULTS[msg.message_type];
  if (!def) return null;
  let href = def.href;
  if (msg.message_type === "result_to_confirm" && msg.fixture_id) {
    const q = new URLSearchParams();
    q.set("fixture", String(msg.fixture_id));
    if (msg.submission_id) q.set("confirm", String(msg.submission_id));
    href = `matchday.html?${q.toString()}`;
  } else if (msg.message_type === "result_submitted" && msg.fixture_id) {
    href = `matchday.html?fixture=${msg.fixture_id}`;
  } else if (
    (msg.message_type === "match_time_proposed" ||
      msg.message_type === "match_time_countered" ||
      msg.message_type === "match_time_proposal_sent" ||
      msg.message_type === "match_time_counter_sent" ||
      msg.message_type === "match_time_accepted") &&
    msg.fixture_id
  ) {
    href = `fixture_schedule.html?fixture=${msg.fixture_id}`;
  } else if (
    (msg.message_type === "match_rescheduled" ||
      msg.message_type === "match_emergency_drop" ||
      msg.message_type === "match_forfeit_applied" ||
      msg.message_type === "match_mutual_override_requested" ||
      msg.message_type === "match_mutual_override_applied") &&
    msg.fixture_id
  ) {
    href = `fixture_schedule.html?fixture=${msg.fixture_id}`;
  }
  return { label: def.label, href };
}
