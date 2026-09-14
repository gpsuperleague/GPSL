-- =============================================================================
-- Match video fines: lock grace at 72h + rescind any still inside that window
-- (2026-09-14)
--
-- Clubs fined under the old 48h rule while lock_at + 72h has not yet passed
-- get money (and any ladder points) reversed; failure rows removed so they
-- can be assessed again only after the new 72h grace ends.
--
-- Safe re-run (already-rescinded failures are gone; reversal ledger is tagged).
-- =============================================================================

-- Force live setting to 72h
ALTER TABLE public.gpsl_discord_match_videos_settings
  ALTER COLUMN missing_fine_grace_hours SET DEFAULT 72;

UPDATE public.gpsl_discord_match_videos_settings
SET
  missing_fine_grace_hours = 72,
  updated_at = now()
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.match_video_missing_fine_grace_hours()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v int;
BEGIN
  SELECT s.missing_fine_grace_hours INTO v
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;
  RETURN greatest(1, coalesce(v, 72));
END;
$function$;

UPDATE public.competition_fine_tariff
SET
  label = 'Missing match video (after 72h grace)',
  updated_at = now()
WHERE code = 'match_video_missing';

-- ---------------------------------------------------------------------------
-- Rescind missing-video assessments still inside grace (default 72h)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_rescind_fines_inside_grace(
  p_grace_hours int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_grace int := coalesce(
    nullif(p_grace_hours, 0),
    public.match_video_missing_fine_grace_hours(),
    72
  );
  v_fail record;
  v_ledger public.competition_finance_ledger%ROWTYPE;
  v_refund numeric;
  v_new_ledger_id bigint;
  v_rescued int := 0;
  v_money int := 0;
  v_pts int := 0;
  v_esc int := 0;
  v_skipped int := 0;
  v_details jsonb := '[]'::jsonb;
  v_esc_row public.match_video_strike_escalations%ROWTYPE;
BEGIN
  IF NOT (
    coalesce(auth.role(), '') = 'service_role'
    OR coalesce(public.is_gpsl_admin_or_mod(), false)
    OR current_user IN ('postgres', 'supabase_admin')
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_grace < 1 THEN
    v_grace := 72;
  END IF;

  FOR v_fail IN
    SELECT
      fail.*,
      f.matchday,
      cal.lock_at,
      cal.lock_at + make_interval(hours => v_grace) AS grace_ends_at
    FROM public.fixture_match_video_failures fail
    JOIN public.competition_fixtures f ON f.id = fail.fixture_id
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE cal.lock_at IS NOT NULL
      AND cal.lock_at + make_interval(hours => v_grace) > now()
    ORDER BY fail.id
  LOOP
    -- Skip if we already posted a rescind for this failure ledger
    IF v_fail.ledger_id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE (l.metadata->>'rescind_of_ledger_id') = v_fail.ledger_id::text
         OR (l.metadata->>'rescind_of_failure_id') = v_fail.id::text
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Reverse money fine
    v_refund := 0;
    IF v_fail.ledger_id IS NOT NULL THEN
      SELECT * INTO v_ledger
      FROM public.competition_finance_ledger
      WHERE id = v_fail.ledger_id;

      IF FOUND AND v_ledger.amount < 0 THEN
        v_refund := abs(v_ledger.amount);
        PERFORM public.competition_credit_club_balance(
          v_fail.club_short_name,
          v_refund
        );

        INSERT INTO public.competition_finance_ledger (
          season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
        )
        VALUES (
          v_fail.season_id,
          v_fail.fixture_id,
          v_fail.club_short_name,
          'gov_fine_compensation',
          v_refund,
          format(
            'Compensation — Missing match video — Rescinded (still within %sh grace)',
            v_grace
          ),
          jsonb_build_object(
            'tariff_code', 'match_video_missing',
            'direction', 'compensation',
            'category', 'matchday',
            'rescind_of_ledger_id', v_fail.ledger_id,
            'rescind_of_failure_id', v_fail.id,
            'rescind_reason', 'inside_grace_window',
            'grace_hours', v_grace
          )
        )
        RETURNING id INTO v_new_ledger_id;

        IF v_fail.fine_applied_id IS NOT NULL THEN
          UPDATE public.competition_fine_applied
          SET note = concat_ws(
            E'\n',
            nullif(btrim(coalesce(note, '')), ''),
            format('RESCINDED %s (still within %sh grace); refund ledger %s',
              now()::date, v_grace, v_new_ledger_id)
          )
          WHERE id = v_fail.fine_applied_id;
        END IF;

        v_money := v_money + 1;
      END IF;
    ELSIF coalesce(v_fail.fine_amount, 0) > 0 THEN
      -- Failure recorded amount but no ledger id — refund from fine_amount
      v_refund := abs(v_fail.fine_amount);
      PERFORM public.competition_credit_club_balance(v_fail.club_short_name, v_refund);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fail.season_id,
        v_fail.fixture_id,
        v_fail.club_short_name,
        'gov_fine_compensation',
        v_refund,
        format(
          'Compensation — Missing match video — Rescinded (still within %sh grace)',
          v_grace
        ),
        jsonb_build_object(
          'tariff_code', 'match_video_missing',
          'direction', 'compensation',
          'category', 'matchday',
          'rescind_of_failure_id', v_fail.id,
          'rescind_reason', 'inside_grace_window',
          'grace_hours', v_grace
        )
      );
      v_money := v_money + 1;
    END IF;

    -- Reverse full −1 if already converted
    IF v_fail.pts_adjustment_id IS NOT NULL THEN
      BEGIN
        PERFORM public.match_video_apply_league_points(
          v_fail.club_short_name,
          (1)::smallint,
          format(
            'Match video — rescinded full 1 pt (still within %sh grace; fixture %s %s)',
            v_grace,
            v_fail.fixture_id,
            v_fail.side
          ),
          v_fail.season_id
        );
        v_pts := v_pts + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    -- If this failure triggered the 3-strike escalate, reverse −9 + pending carry
    SELECT * INTO v_esc_row
    FROM public.match_video_strike_escalations e
    WHERE e.third_failure_id = v_fail.id
       OR (
         e.season_id = v_fail.season_id
         AND upper(btrim(e.club_short_name)) = upper(btrim(v_fail.club_short_name))
         AND e.third_failure_id IS NULL
       )
    LIMIT 1;

    IF FOUND AND v_esc_row.id IS NOT NULL
       AND v_esc_row.third_failure_id IS NOT DISTINCT FROM v_fail.id THEN
      IF v_esc_row.season_adjustment_id IS NOT NULL THEN
        BEGIN
          PERFORM public.match_video_apply_league_points(
            v_fail.club_short_name,
            (9)::smallint,
            format(
              'Match video — rescinded 3-strike −9 (still within %sh grace)',
              v_grace
            ),
            v_fail.season_id
          );
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END IF;

      DELETE FROM public.match_video_points_carry c
      WHERE c.escalation_id = v_esc_row.id
        AND c.applied_at IS NULL;

      DELETE FROM public.match_video_strike_escalations
      WHERE id = v_esc_row.id;

      v_esc := v_esc + 1;
    END IF;

    BEGIN
      PERFORM public.owner_inbox_send(
        'fine_applied',
        'Missing match video fine rescinded',
        format(
          E'Your missing match video fine for fixture %s (%s) was rescinded.\n'
          || 'Upload grace is now %s hours after month lock; you are still inside that window.\n'
          || CASE WHEN v_refund > 0
               THEN format('₿%s has been credited back to club finances.',
                 trim(to_char(v_refund, '999,999,999,999')))
               ELSE 'No money fine was on the ledger for this row.'
             END,
          v_fail.fixture_id,
          v_fail.side,
          v_grace
        ),
        v_fail.club_short_name,
        NULL,
        v_fail.fixture_id,
        NULL, NULL, NULL,
        'fixtures.html',
        'mv_fine_rescind:' || v_fail.id::text,
        NULL,
        v_fail.season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    DELETE FROM public.fixture_match_video_failures
    WHERE id = v_fail.id;

    v_rescued := v_rescued + 1;
    v_details := v_details || jsonb_build_array(
      jsonb_build_object(
        'failure_id', v_fail.id,
        'fixture_id', v_fail.fixture_id,
        'side', v_fail.side,
        'club', v_fail.club_short_name,
        'refund', v_refund,
        'grace_ends_at', v_fail.grace_ends_at
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'grace_hours', v_grace,
    'rescinded', v_rescued,
    'money_refunded', v_money,
    'points_reversed', v_pts,
    'escalations_reversed', v_esc,
    'skipped_already', v_skipped,
    'details', v_details
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_rescind_fines_inside_grace(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_rescind_fines_inside_grace(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_rescind_fines_inside_grace(int) TO service_role;

-- One-shot: apply rescinds now (admin / SQL Editor / service_role)
DO $$
DECLARE
  v_result jsonb;
BEGIN
  -- Run as definer; allow when executed from SQL Editor (often postgres / service)
  BEGIN
    v_result := public.match_video_rescind_fines_inside_grace(72);
    RAISE NOTICE 'match_video_rescind_fines_inside_grace: %', v_result;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'match_video_rescind_fines_inside_grace failed: %', SQLERRM;
  END;
END $$;

NOTIFY pgrst, 'reload schema';
