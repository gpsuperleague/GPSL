-- =============================================================================
-- Auto-apply playoff movements from outcomes
--
-- Already true today:
--   • Fixtures update competition_playoff_ties winners/losers
--   • Shield/Bowl prestige qualifiers upsert on CH 16v17
--   • competition_apply_playoff_movements() builds competition_season_movements
--     from table + playoff winners (admin button only)
--
-- This patch:
--   1) When SL playoff final is played → apply movements automatically
--   2) When Playoffs month locks → apply if SL final done and not yet applied
-- Safe re-run. Manual “Apply movements” remains as a re-run/repair.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_playoff_try_apply_movements(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_state public.competition_playoff_season_state%ROWTYPE;
  v_sl_final public.competition_playoff_ties%ROWTYPE;
  v_out jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT * INTO v_state
  FROM public.competition_playoff_season_state
  WHERE season_id = v_season_id;

  SELECT * INTO v_sl_final
  FROM public.competition_playoff_ties
  WHERE season_id = v_season_id
    AND bracket = 'sl_final'
  LIMIT 1;

  IF NOT FOUND OR v_sl_final.status IS DISTINCT FROM 'played' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'sl_final_not_played',
      'season_id', v_season_id
    );
  END IF;

  -- Already applied and still matches a completed final — skip unless forced via admin button
  IF v_state.movements_applied_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'already_applied',
      'season_id', v_season_id,
      'movements_applied_at', v_state.movements_applied_at
    );
  END IF;

  IF to_regprocedure('public.competition_apply_playoff_movements(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'apply_rpc_missing');
  END IF;

  v_out := public.competition_apply_playoff_movements(v_season_id);
  RETURN coalesce(v_out, '{}'::jsonb) || jsonb_build_object('auto', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_playoff_try_apply_movements(bigint)
  TO authenticated, service_role;

-- Hook: SL final played → auto apply
CREATE OR REPLACE FUNCTION public.competition_playoff_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t public.competition_playoff_ties%ROWTYPE;
  v_winner text;
  v_loser text;
  v_div text;
  v_mov jsonb;
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.competition_type IS DISTINCT FROM 'cup'
     OR NEW.cup_code IS NULL
     OR NEW.cup_code NOT LIKE 'po_%' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO t
  FROM public.competition_playoff_ties
  WHERE fixture_id = NEW.id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_winner := public.competition_playoff_fixture_winner(NEW);
  IF v_winner IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_winner = NEW.home_club_short_name THEN
    v_loser := NEW.away_club_short_name;
  ELSE
    v_loser := NEW.home_club_short_name;
  END IF;

  UPDATE public.competition_playoff_ties
  SET winner_club_short_name = v_winner,
      loser_club_short_name = v_loser,
      status = 'played'
  WHERE id = t.id;

  -- Shield/Bowl prestige qualifiers
  IF t.bracket IN ('ch_sb_a', 'ch_sb_b') THEN
    v_div := CASE t.bracket WHEN 'ch_sb_a' THEN 'championship_a' ELSE 'championship_b' END;
    BEGIN
      INSERT INTO public.competition_cup_manual_qualifiers (
        season_id, cup_code, division, club_short_name, qualifier_role
      ) VALUES
        (NEW.season_id, 'shield', v_div, v_winner, 'shield_playoff_winner'),
        (NEW.season_id, 'bowl', v_div, v_loser, 'bowl_playoff_loser')
      ON CONFLICT (season_id, cup_code, division, qualifier_role)
      DO UPDATE SET club_short_name = excluded.club_short_name;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  PERFORM public.competition_playoff_fill_from_sources(NEW.season_id);
  PERFORM public.competition_playoff_try_schedule_ready(NEW.season_id);

  IF t.bracket = 'sl_final' THEN
    UPDATE public.competition_playoff_season_state
    SET completed_at = now(),
        notes = coalesce(notes, '{}'::jsonb) || jsonb_build_object(
          'sl_final_winner', v_winner,
          'sl_final_loser', v_loser
        )
    WHERE season_id = NEW.season_id;

    BEGIN
      v_mov := public.competition_playoff_try_apply_movements(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      v_mov := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    BEGIN
      PERFORM public.gpsl_discord_feed_enqueue(
        'league_clinch',
        format(
          '🏁 PLAYOFFS COMPLETE — %s win the SuperLeague playoff final',
          coalesce(
            (SELECT c."Club" FROM public."Clubs" c WHERE c."ShortName" = v_winner),
            v_winner
          )
        ),
        CASE
          WHEN coalesce((v_mov->>'ok')::boolean, false)
               AND coalesce((v_mov->>'skipped')::boolean, false) IS NOT TRUE
            THEN format(
              'Promotion / relegation movements recorded automatically (%s rows).',
              coalesce(v_mov->>'movements', '?')
            )
          WHEN coalesce((v_mov->>'skipped')::boolean, false)
               AND v_mov->>'reason' = 'already_applied'
            THEN 'End-of-season movements were already recorded.'
          ELSE
            'Playoffs finished. If movements did not auto-apply, use Admin → Playoffs → Apply movements.'
        END,
        16766720,
        'playoffs_complete:' || NEW.season_id::text,
        jsonb_build_object(
          'channel', 'news',
          'season_id', NEW.season_id,
          'movements', v_mov
        )
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_playoff_fixture_played ON public.competition_fixtures;
CREATE TRIGGER trg_competition_playoff_fixture_played
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals, cup_pen_winner_club_short_name
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.competition_playoff_on_fixture_played();

-- Safety net: Playoffs month lock tries apply if SL final done
CREATE OR REPLACE FUNCTION public.competition_month_lock_try_apply_playoff_movements(
  p_season_id bigint,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(nullif(btrim(coalesce(p_locked_gpsl_month, '')), ''));
BEGIN
  IF v_month IS DISTINCT FROM 'playoffs' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'not_playoffs_lock',
      'gpsl_month', v_month
    );
  END IF;

  RETURN public.competition_playoff_try_apply_movements(p_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_month_lock_try_apply_playoff_movements(bigint, text)
  TO service_role;

-- Wire into month-lock playoffs stage (after generate) via soft append in admin runner
-- Prefer injecting into competition_run_month_lock_jobs playoffs block when present.
DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs(4-arg) missing — skip wire';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL OR position('playoff_movements' IN v_def) > 0 THEN
    IF position('playoff_movements' IN coalesce(v_def, '')) > 0 THEN
      RAISE NOTICE 'playoff movements already wired into month-lock jobs';
    END IF;
    RETURN;
  END IF;

  -- After playoffs result is attached to v_out, also try apply when locking playoffs
  v_old := 'v_out := v_out || jsonb_build_object(''playoffs'', v_playoffs);';
  IF position(v_old IN v_def) = 0 THEN
    v_old := 'v_out := v_out || jsonb_build_object("playoffs", v_playoffs);';
  END IF;

  IF position('v_out := v_out || jsonb_build_object(''playoffs'', v_playoffs);' IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate playoffs attach — skip month-lock wire (SL-final auto-apply still works)';
    RETURN;
  END IF;

  v_new :=
    'v_out := v_out || jsonb_build_object(''playoffs'', v_playoffs);'
    || E'\n      BEGIN'
    || E'\n        IF to_regprocedure(''public.competition_month_lock_try_apply_playoff_movements(bigint,text)'') IS NOT NULL THEN'
    || E'\n          v_out := v_out || jsonb_build_object('
    || E'\n            ''playoff_movements'','
    || E'\n            public.competition_month_lock_try_apply_playoff_movements(p_season_id, v_month)'
    || E'\n          );'
    || E'\n        END IF;'
    || E'\n      EXCEPTION'
    || E'\n        WHEN OTHERS THEN'
    || E'\n          v_out := v_out || jsonb_build_object('
    || E'\n            ''playoff_movements'','
    || E'\n            jsonb_build_object(''ok'', false, ''error'', SQLERRM)'
    || E'\n          );'
    || E'\n      END;';

  v_def := replace(
    v_def,
    'v_out := v_out || jsonb_build_object(''playoffs'', v_playoffs);',
    v_new
  );

  BEGIN
    EXECUTE v_def;
    RAISE NOTICE 'Wired playoff movements into competition_run_month_lock_jobs';
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'Month-lock wire failed (%); SL-final auto-apply still active', SQLERRM;
  END;
END;
$wire$;

NOTIFY pgrst, 'reload schema';
