-- =============================================================================
-- Admin: send sample of every inbox notification type to all owned clubs
-- Requires owner_inbox_send (owner_inbox_fine_fix.sql or owner_inbox_notifications.sql)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_inbox_admin_clear_test_notifications(
  p_batch text DEFAULT 'preview'
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_batch text := coalesce(nullif(btrim(p_batch), ''), 'preview');
  v_count int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.competition_inbox
  WHERE dedupe_key LIKE 'test:' || v_batch || ':%';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_admin_send_test_notifications(
  p_batch text DEFAULT 'preview',
  p_resend boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_batch text := coalesce(nullif(btrim(p_batch), ''), 'preview');
  v_club record;
  v_club_name text;
  v_sent int := 0;
  v_skipped int := 0;
  v_cleared int := 0;
  v_types text[] := ARRAY[
    'welcome_gpsl',
    'result_submitted',
    'result_to_confirm',
    'result_rejected',
    'result_confirmed',
    'transfer_signed',
    'transfer_sold',
    'transfer_upcoming',
    'draft_scheduled',
    'fine_applied',
    'points_deduction',
    'nation_pick_turn',
    'nation_selection_open',
    'season_expectations',
    'season_overview',
    'player_awards',
    'monthly_fixtures'
  ];
  v_type text;
  v_title text;
  v_body text;
  v_href text;
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_resend THEN
    v_cleared := public.owner_inbox_admin_clear_test_notifications(v_batch);
  END IF;

  FOR v_club IN
    SELECT c."ShortName" AS short_name, c."Club" AS club_name
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
    ORDER BY c."Club"
  LOOP
    v_club_name := coalesce(v_club.club_name, v_club.short_name);

    FOREACH v_type IN ARRAY v_types LOOP
      v_title := NULL;
      v_body := NULL;
      v_href := NULL;

      CASE v_type
        WHEN 'welcome_gpsl' THEN
          v_title := '[TEST] Welcome to GPSL';
          v_body := format(
            E'Welcome to GPSL — you are linked to %s.\n\nRead Learning GPSL for navigation, auctions, contracts, and club expectations.',
            v_club_name
          );
          v_href := 'learning_gpsl.html';

        WHEN 'result_submitted' THEN
          v_title := '[TEST] Result submitted: ' || v_club_name || ' vs Opponent FC';
          v_body := E'GPSL month 3 — you submitted Home Team 2–1 Away Team.\nWaiting for your opponent to confirm or reject.';
          v_href := 'matchday.html';

        WHEN 'result_to_confirm' THEN
          v_title := '[TEST] Confirm result: ' || v_club_name || ' vs Opponent FC';
          v_body := E'GPSL month 3 — Opponent FC submitted 2–1. Confirm or reject.';
          v_href := 'matchday.html';

        WHEN 'result_rejected' THEN
          v_title := '[TEST] Result rejected: ' || v_club_name || ' vs Opponent FC';
          v_body := E'Your submitted score 2–1 was rejected.\nReason: Score does not match our records.';
          v_href := 'matchday.html';

        WHEN 'result_confirmed' THEN
          v_title := '[TEST] Result confirmed: ' || v_club_name || ' vs Opponent FC';
          v_body := E'GPSL month 3 — 2–1 confirmed. Table, stats, and gates updated.';
          v_href := 'fixtures.html';

        WHEN 'transfer_signed' THEN
          v_title := '[TEST] Signed Sample Striker';
          v_body := format(
            E'Player: Sample Striker\nMethod: Transfer list (auction)\nSigned from: Rival United\nYour club: %s\nFee paid: ₿ 12,500,000',
            v_club_name
          );
          v_href := 'squad.html';

        WHEN 'transfer_sold' THEN
          v_title := '[TEST] Sold Sample Winger';
          v_body := format(
            E'Player: Sample Winger\nMethod: Direct offer (transfer market)\nSold to: Buyer City\nYour club: %s\nSale proceeds: ₿ 8,000,000',
            v_club_name
          );
          v_href := 'finances.html';

        WHEN 'transfer_upcoming' THEN
          v_title := '[TEST] Transfer window is open';
          v_body := E'The transfer window is now open. List players, make offers, and watch the transfer market.';
          v_href := 'transfer_center.html';

        WHEN 'draft_scheduled' THEN
          v_title := '[TEST] Manager draft auction scheduled';
          v_body := E'Manager draft auction opens Fri 19:00 UK.\nBidding closes at a secret random time — the MGDB countdown never shows the exact moment in advance.\nCheck MGDB and Manager Draft Auction.';
          v_href := 'manager_draftauction.html';

        WHEN 'fine_applied' THEN
          v_title := '[TEST] Fine applied';
          v_body := E'Fine — Matchday misconduct\nAmount: ₿ 30,000,000\nNote: Sample test notification';
          v_href := 'finances.html';

        WHEN 'points_deduction' THEN
          v_title := '[TEST] League points deduction';
          v_body := E'3 point(s) deducted.\nReason: Sample disciplinary deduction (test only).';
          v_href := 'progress.html';

        WHEN 'nation_pick_turn' THEN
          v_title := '[TEST] Your turn — pick a nation';
          v_body := E'Nation selection: you are pick #12 of 60.\nChoose your national team on the Nation selection page.';
          v_href := 'nation_select.html';

        WHEN 'nation_selection_open' THEN
          v_title := '[TEST] Nation selection is open';
          v_body := E'The international nation draft has started. You will receive a message when it is your turn.';
          v_href := 'nation_select.html';

        WHEN 'season_expectations' THEN
          v_title := '[TEST] Season expectations';
          v_body := format(
            E'Manager: Alex Sample (rating 84, 2 season(s) remaining)\nLeague target: Top 8 in your division to retain your manager.\nStadium: maintain strong attendance — current fill 88%%, season target 100%%.\nYour club: %s',
            v_club_name
          );
          v_href := 'stadium.html';

        WHEN 'season_overview' THEN
          v_title := '[TEST] Season overview — 2025/26';
          v_body := format(
            E'Final league position: 5 in championship_a (58 pts, 16W-10D-12L)\nManager: Alex Sample — 2 season(s) on contract\nStar player: Sample Striker\nYour club: %s',
            v_club_name
          );
          v_href := 'history.html';

        WHEN 'player_awards' THEN
          v_title := '[TEST] Season awards — 2025/26';
          v_body := E'golden boot: Sample Striker (24)\nseason potm: Sample Midfielder (7)\nballon dor: Sample Striker (412)';
          v_href := 'history.html';

        WHEN 'monthly_fixtures' THEN
          v_title := '[TEST] GPSL month 4 — your matches';
          v_body := format(
            E'• Home vs Rival United (league)\n  Opponent record: 10W-6D-8L, 36 pts, pos 7. Form: WDLWW\n  Manager: Rival Boss\n  Top rated: Star A, Star B, Star C\n  Goal threats: Striker X (15), Striker Y (9)\n  Top assists: Playmaker Z (8)\n\n• Away at City Athletic (league)\n  Opponent record: 8W-8D-8L, 32 pts, pos 9. Form: DDWLW\n  Manager: City Gaffer\n  Top rated: Ace One, Ace Two, Ace Three\n  Goal threats: Forward P (11)\n  Top assists: Winger Q (6)',
            v_club_name
          );
          v_href := 'fixtures.html';

        ELSE
          CONTINUE;
      END CASE;

      v_id := public.owner_inbox_send(
        v_type,
        v_title,
        v_body,
        v_club.short_name,
        NULL,
        NULL, NULL, NULL, NULL,
        v_href,
        'test:' || v_batch || ':' || v_type || ':' || v_club.short_name,
        CASE WHEN v_type = 'monthly_fixtures' THEN 'august'::text ELSE NULL END,
        NULL
      );

      IF v_id IS NOT NULL THEN
        v_sent := v_sent + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'batch', v_batch,
    'clubs', (SELECT count(*)::int FROM public."Clubs" WHERE owner_id IS NOT NULL),
    'types', coalesce(array_length(v_types, 1), 0),
    'cleared', v_cleared,
    'sent', v_sent,
    'skipped', v_skipped
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_admin_clear_test_notifications(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_admin_send_test_notifications(text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
