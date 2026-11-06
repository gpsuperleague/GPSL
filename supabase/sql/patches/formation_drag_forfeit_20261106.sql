-- =============================================================================
-- Dragging a player off the default formation dots forfeits the match 0–3.
-- The shape is set before kick-off. An in-match change must be another
-- default Konami formation. Fluid on does not allow manual moves.
--
-- Adds the video-report code formation_player_drag. Approving a report that
-- includes it writes the official result as a 0–3 forfeit to the opponent.
-- No cash fine on this code.
-- Run once in the Supabase SQL Editor.
-- =============================================================================

INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'formation_player_drag',
  'Dragged players off the default formation (instant 0–3 forfeit)',
  'matchday',
  'fine',
  0,
  'fixed',
  84,
  true
)
ON CONFLICT (code) DO UPDATE
SET
  label = excluded.label,
  category = excluded.category,
  direction = excluded.direction,
  amount = excluded.amount,
  amount_mode = excluded.amount_mode,
  sort_order = excluded.sort_order,
  is_active = true,
  updated_at = now();

CREATE OR REPLACE FUNCTION public.fixture_apply_formation_drag_forfeit(
  p_fixture_id bigint,
  p_loser_club text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_was_played boolean;
  v_home_goals smallint;
  v_away_goals smallint;
  v_winner text;
  v_reason text := coalesce(
    nullif(btrim(coalesce(p_reason, '')), ''),
    'Dragged players off the default formation'
  );
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF upper(btrim(p_loser_club)) NOT IN (
    upper(btrim(v_fixture.home_club_short_name)),
    upper(btrim(v_fixture.away_club_short_name))
  ) THEN
    RAISE EXCEPTION 'Loser must be a club in this fixture';
  END IF;

  v_was_played := v_fixture.status = 'played';

  v_winner := CASE
    WHEN upper(btrim(p_loser_club)) = upper(btrim(v_fixture.home_club_short_name))
      THEN v_fixture.away_club_short_name
    ELSE v_fixture.home_club_short_name
  END;

  IF v_winner = v_fixture.home_club_short_name THEN
    v_home_goals := 3;
    v_away_goals := 0;
  ELSE
    v_home_goals := 0;
    v_away_goals := 3;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by formation-drag forfeit',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET
    home_goals = v_home_goals,
    away_goals = v_away_goals,
    status = 'played',
    is_forfeit = true,
    forfeit_loser_club = CASE
      WHEN upper(btrim(p_loser_club)) = upper(btrim(v_fixture.home_club_short_name))
        THEN v_fixture.home_club_short_name
      ELSE v_fixture.away_club_short_name
    END
  WHERE id = p_fixture_id;

  IF NOT v_was_played THEN
    IF v_fixture.competition_type = 'cup'
       AND to_regprocedure('public.competition_cup_on_fixture_played(bigint)') IS NOT NULL THEN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    ELSIF v_fixture.competition_type = 'league'
       AND to_regprocedure('public.competition_try_pay_league_division_prizes(bigint, text)') IS NOT NULL THEN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id,
        v_fixture.division
      );
    END IF;
  END IF;

  v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Match forfeited');
  v_body := public.competition_fixture_inbox_body(
    p_fixture_id,
    format(
      '%s forfeited 0–3 for dragging a player off the default formation. %s',
      public.club_display_name(
        CASE
          WHEN upper(btrim(p_loser_club)) = upper(btrim(v_fixture.home_club_short_name))
            THEN v_fixture.home_club_short_name
          ELSE v_fixture.away_club_short_name
        END
      ),
      v_reason
    )
  );

  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.home_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'formation-drag:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.away_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'formation-drag:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_goals', v_home_goals,
    'away_goals', v_away_goals,
    'was_already_played', v_was_played,
    'loser', p_loser_club
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_apply_formation_drag_forfeit(bigint, text, text)
  FROM PUBLIC, anon;

-- Approve path: this code forfeits the match instead of posting a cash fine.
CREATE OR REPLACE FUNCTION public.admin_match_video_resolve_breach_report(
  p_report_id bigint,
  p_action text,
  p_tariff_code text DEFAULT NULL,
  p_review_note text DEFAULT NULL,
  p_amount_override numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_action text := lower(btrim(p_action));
  v_uid uuid := auth.uid();
  v_r public.match_video_breach_reports%ROWTYPE;
  v_item jsonb;
  v_code text;
  v_note text;
  v_apply jsonb;
  v_fines jsonb := '[]'::jsonb;
  v_reward_id bigint;
  v_reward numeric := 2000;
  v_forfeit jsonb;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  IF v_action IN ('uphold', 'ok', 'approve') THEN
    v_action := 'approve';
  ELSIF v_action IN ('dismiss', 'reject') THEN
    v_action := 'reject';
  END IF;

  IF v_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'action must be approve or reject';
  END IF;

  SELECT * INTO v_r
  FROM public.match_video_breach_reports
  WHERE id = p_report_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Report not found';
  END IF;
  IF v_r.status <> 'open' THEN
    RAISE EXCEPTION 'Report already resolved';
  END IF;

  IF v_action = 'reject' THEN
    UPDATE public.match_video_breach_reports
    SET status = 'rejected',
        reviewed_at = now(),
        reviewed_by = v_uid,
        review_note = nullif(btrim(coalesce(p_review_note, '')), '')
    WHERE id = p_report_id;

    RETURN jsonb_build_object('ok', true, 'status', 'rejected', 'report_id', p_report_id);
  END IF;

  FOR v_item IN
    SELECT * FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(coalesce(v_r.breaches, '[]'::jsonb)) = 'array'
             AND jsonb_array_length(v_r.breaches) > 0
          THEN v_r.breaches
        ELSE jsonb_build_array(
          jsonb_build_object(
            'code', coalesce(nullif(btrim(coalesce(p_tariff_code, '')), ''), v_r.breach_tariff_code),
            'note', coalesce(v_r.note, format('Match video breach report #%s', p_report_id))
          )
        )
      END
    )
  LOOP
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF v_code = '' THEN
      CONTINUE;
    END IF;

    IF v_code = 'formation_player_drag' THEN
      BEGIN
        v_forfeit := public.fixture_apply_formation_drag_forfeit(
          v_r.fixture_id,
          v_r.accused_club_short_name,
          coalesce(nullif(v_note, ''), 'Dragged players off the default formation')
        );
        v_fines := v_fines || jsonb_build_array(
          jsonb_build_object('code', v_code, 'forfeit', v_forfeit)
        );
      EXCEPTION WHEN OTHERS THEN
        v_fines := v_fines || jsonb_build_array(
          jsonb_build_object('code', v_code, 'error', SQLERRM)
        );
      END;
      CONTINUE;
    END IF;

    BEGIN
      v_apply := public.competition_apply_club_fine_tariff(
        v_r.accused_club_short_name,
        v_code,
        p_amount_override,
        coalesce(
          nullif(v_note, ''),
          format('Match video breach report #%s', p_report_id)
        ),
        v_r.fixture_id,
        v_r.season_id
      );
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'apply', v_apply)
      );
    EXCEPTION WHEN OTHERS THEN
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'error', SQLERRM)
      );
    END;
  END LOOP;

  BEGIN
    PERFORM public.owner_wallet_ensure(v_r.reporter_owner_id);
    v_reward_id := public._post_owner_ledger_internal(
      v_r.reporter_owner_id,
      'match_video_report_reward',
      v_reward,
      format('Match video report approved (#%s)', p_report_id),
      jsonb_build_object(
        'source', 'match_video_breach_report',
        'report_id', p_report_id,
        'fixture_id', v_r.fixture_id
      ),
      v_r.season_id,
      true
    );
  EXCEPTION WHEN OTHERS THEN
    v_reward_id := NULL;
  END;

  UPDATE public.match_video_breach_reports
  SET status = 'approved',
      reviewed_at = now(),
      reviewed_by = v_uid,
      review_note = nullif(btrim(coalesce(p_review_note, '')), ''),
      upheld_tariff_code = coalesce(v_r.breaches->0->>'code', v_r.breach_tariff_code),
      fine_applied_id = nullif(v_fines->0->'apply'->>'applied_id', '')::bigint,
      fine_ledger_id = nullif(v_fines->0->'apply'->>'ledger_id', '')::bigint,
      reward_ledger_id = v_reward_id
  WHERE id = p_report_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'approved',
    'report_id', p_report_id,
    'fines', v_fines,
    'reward_ledger_id', v_reward_id,
    'reward_amount', v_reward
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
