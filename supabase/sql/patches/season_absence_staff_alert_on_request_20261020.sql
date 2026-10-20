-- =============================================================================
-- Staff alert when an owner requests season absence
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_club_season_absence_request(p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_owner uuid := auth.uid();
  v_club text;
  v_club_name text;
  v_season_id bigint;
  v_num int;
  v_elig jsonb;
  v_id bigint;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_body text;
  v_alert_id bigint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT c."ShortName", c."Club" INTO v_club, v_club_name
  FROM public."Clubs" c
  WHERE c.owner_id = v_owner
  LIMIT 1;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  IF public.club_is_season_absent(v_club, v_season_id) THEN
    RAISE EXCEPTION 'Already on season absence';
  END IF;

  v_elig := public.owner_season_absence_eligible(v_owner, v_season_id);
  IF NOT coalesce((v_elig->>'eligible')::boolean, false) THEN
    RAISE EXCEPTION 'Not eligible (1 season in 4)';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_season_absences a
    WHERE a.club_short_name = v_club AND a.season_id = v_season_id
      AND a.status = 'requested'
  ) THEN
    RAISE EXCEPTION 'Request already pending admin approval';
  END IF;

  v_num := public.club_loan_game_season_number(v_season_id);

  INSERT INTO public.club_season_absences (
    owner_id, club_short_name, season_id, game_season_number, status, note
  ) VALUES (
    v_owner, v_club, v_season_id, v_num, 'requested', v_note
  )
  RETURNING id INTO v_id;

  -- Staff alert so admins do not have to poll Season absence
  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    BEGIN
      v_body := format(
        E'%s (%s) requested season absence for the current season.\nApprove or reject on Admin → Season absence.',
        coalesce(nullif(btrim(v_club_name), ''), v_club),
        v_club
      );
      IF v_note IS NOT NULL THEN
        v_body := v_body || E'\n\nOwner note: ' || v_note;
      END IF;

      v_alert_id := public.gpsl_staff_alert_create(
        'season_absence_request',
        format('Season absence requested: %s', v_club),
        v_body,
        'admin_season_absence.html',
        jsonb_build_object(
          'club_short_name', v_club,
          'season_id', v_season_id,
          'absence_id', v_id,
          'owner_id', v_owner
        ),
        format('season_absence_request:%s:%s', v_club, v_season_id)
      );
    EXCEPTION WHEN OTHERS THEN
      v_alert_id := NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_id,
    'status', 'requested',
    'club', v_club,
    'staff_alert_id', v_alert_id
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.owner_club_season_absence_request(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
