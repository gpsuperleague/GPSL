// Shared matchday submit / confirm actions (Phase 3)

export async function submitFixtureResult(supabase, fixtureId, homeGoals, awayGoals) {
  return supabase.rpc("competition_submit_result", {
    p_fixture_id: fixtureId,
    p_home_goals: homeGoals,
    p_away_goals: awayGoals,
  });
}

export async function confirmFixtureResult(supabase, submissionId) {
  return supabase.rpc("competition_confirm_result", {
    p_submission_id: submissionId,
  });
}

export async function rejectFixtureResult(supabase, submissionId, reason = null) {
  return supabase.rpc("competition_reject_result", {
    p_submission_id: submissionId,
    p_reason: reason,
  });
}

export function canSubmitResult(fixture, clubShort) {
  if (!fixture || !clubShort) return false;
  const involved =
    fixture.home_club_short_name === clubShort ||
    fixture.away_club_short_name === clubShort;
  return (
    involved &&
    fixture.status === "scheduled" &&
    !fixture.submission_id
  );
}

export function needsInboxConfirm(fixture, clubShort) {
  if (!fixture || !clubShort) return false;
  return (
    fixture.submission_status === "pending" &&
    fixture.submitted_by_club &&
    fixture.submitted_by_club !== clubShort
  );
}
