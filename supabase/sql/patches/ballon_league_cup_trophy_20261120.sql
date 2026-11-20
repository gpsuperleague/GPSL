-- League Cup on the Ballon d'Or settings page.
-- Same rule as the other cups: winner's players who appeared at least once.
-- Starts at 0 until an admin saves a number. Safe re-run.

ALTER TABLE public.competition_ballon_settings
  ADD COLUMN IF NOT EXISTS trophy_league_cup numeric NOT NULL DEFAULT 0;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_ballon_settings_set(jsonb)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('trophy_league_cup' IN v_def) = 0 THEN
    v_old := replace($old$    trophy_shield = coalesce((p_settings->>'trophy_shield')::numeric, trophy_shield),
$old$, E'\r\n', E'\n');
    v_new := replace($new$    trophy_shield = coalesce((p_settings->>'trophy_shield')::numeric, trophy_shield),
    trophy_league_cup = coalesce((p_settings->>'trophy_league_cup')::numeric, trophy_league_cup),
$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'admin_ballon_settings_set needle missing';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(
    pg_get_functiondef('public.competition_player_ballon_trophy_bonus(bigint, text, text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('cup_code = ''league_cup''' IN v_def) = 0 THEN
    v_old := replace($old$      v_bonus := v_bonus + coalesce(v.trophy_shield, 0);
    END IF;
  END IF;

  -- World Cup: player's nation won a WC cycle overlapping this GPSL season label year
$old$, E'\r\n', E'\n');
    v_new := replace($new$      v_bonus := v_bonus + coalesce(v.trophy_shield, 0);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.competition_cup_season_winner w
      WHERE w.season_id = p_season_id
        AND w.winner_club_short_name = v_club
        AND w.cup_code = 'league_cup'
    ) AND (
      to_regprocedure('public.competition_player_cup_appearances(bigint,text,text,text)') IS NULL
      OR public.competition_player_cup_appearances(p_season_id, v_player, v_club, 'league_cup') >= 1
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_league_cup, 0);
    END IF;
  END IF;

  -- World Cup: player's nation won a WC cycle overlapping this GPSL season label year
$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'trophy bonus needle missing';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$patch$;

SELECT jsonb_build_object(
  'league_cup_points', (
    SELECT trophy_league_cup FROM public.competition_ballon_settings WHERE id = 1
  ),
  'setter', position(
    'trophy_league_cup' IN pg_get_functiondef('public.admin_ballon_settings_set(jsonb)'::regprocedure)
  ) > 0,
  'bonus', position(
    'league_cup' IN pg_get_functiondef(
      'public.competition_player_ballon_trophy_bonus(bigint, text, text)'::regprocedure
    )
  ) > 0
);
