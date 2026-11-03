-- =============================================================================
-- Handpick: max 3 star-rated players tagged in the basket at once.
-- Uses club_squad_star_min_rating() (default 79). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handpick_star_tag_cap()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 3;
$$;

CREATE OR REPLACE FUNCTION public.handpick_basket_star_count(p_club text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_min numeric := 79;
  v_n int := 0;
BEGIN
  IF v_club IS NULL THEN
    RETURN 0;
  END IF;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := coalesce(public.club_squad_star_min_rating()::numeric, 79);
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.club_handpick_basket b
  JOIN public."Players" p ON p."Konami_ID"::text = b.player_id
  WHERE b.club_short_name = v_club
    AND coalesce(
      nullif(regexp_replace(coalesce(p."Rating"::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
      0
    ) >= v_min;

  RETURN coalesce(v_n, 0);
END;
$function$;

-- Patch toggle: refuse adding a 4th star
CREATE OR REPLACE FUNCTION public.handpick_basket_toggle(
  p_player_id text,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_handpick boolean := false;
  v_exists boolean := false;
  v_team text;
  v_rating numeric := 0;
  v_min numeric := 79;
  v_cap int := public.handpick_star_tag_cap();
  v_stars int;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT v_handpick THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_in_handpick',
      'detail', 'Handpick intake is not open for this club.'
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_club AND player_id = v_pid;
    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'player_id', v_pid,
      'star_tagged', public.handpick_basket_star_count(v_club),
      'star_tag_cap', v_cap
    );
  END IF;

  SELECT nullif(btrim(p."Contracted_Team"::text), ''),
         coalesce(
           nullif(regexp_replace(coalesce(p."Rating"::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
           0
         )
  INTO v_team, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'player_not_found');
  END IF;

  IF v_team IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_free_agent',
      'detail', 'Only free agents can be handpick-tagged.'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
      AND coalesce(p.pesdb_unavailable, false)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'legacy_card');
  END IF;

  IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
     AND public.gpdb_player_is_season_excluded(v_pid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'season_excluded');
  END IF;

  IF to_regprocedure('public.player_foreign_contract_locked(text)') IS NOT NULL
     AND public.player_foreign_contract_locked(v_pid) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'foreign_or_paid_up_lock',
      'detail', 'Unavailable until next season (foreign / paid-up lock).'
    );
  END IF;

  BEGIN
    IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
      PERFORM public.assert_player_available_for_signing(v_pid);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_signable',
      'detail', SQLERRM
    );
  END;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := coalesce(public.club_squad_star_min_rating()::numeric, 79);
  END IF;

  IF v_rating >= v_min THEN
    v_stars := public.handpick_basket_star_count(v_club);
    IF v_stars >= v_cap THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'star_tag_cap',
        'detail', format(
          'Handpick allows at most %s star players (≥%s) tagged at once. Untag a star first.',
          v_cap, v_min
        ),
        'star_tagged', v_stars,
        'star_tag_cap', v_cap,
        'star_min_rating', v_min
      );
    END IF;
  END IF;

  INSERT INTO public.club_handpick_basket (club_short_name, player_id, added_by)
  VALUES (v_club, v_pid, auth.uid())
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', true,
    'club', v_club,
    'player_id', v_pid,
    'star_tagged', public.handpick_basket_star_count(v_club),
    'star_tag_cap', v_cap
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_star_tag_cap() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_basket_star_count(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_basket_toggle(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_star_tag_cap() TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_basket_star_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_basket_toggle(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
