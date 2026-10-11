-- =============================================================================
-- Squad over 28: fix overflow release never running
--
-- Bug: emergency_loan_status_cap_fix_20260905.sql rewrote
-- enforce_squad_overflow_after_signing to call club_sell_player_to_foreign(),
-- which doesn't exist (the real one is club_release_player_foreign_overflow).
-- Any club with foreign interest left errored out; the draft run swallows
-- that as a WARNING, so clubs (e.g. ACM, 31 after Sat 10 Oct draft) stayed
-- over 28 with no release and no fine.
--
-- This patch:
--   1) Restores the correct foreign-overflow call (permanent-squad count,
--      emergency loans still exempt)
--   2) Deferred end-of-run pass uses the same permanent count
--   3) READ-ONLY report: every club over 28 and who the rule would release
-- Does NOT release anyone. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.enforce_squad_overflow_after_signing(
  p_club_short_name text,
  p_new_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_total int;
  v_release text;
  v_interest int;
  v_teams text[];
  v_team text;
  v_result jsonb;
BEGIN
  v_total := public.club_permanent_squad_count(v_club);

  IF v_total <= public.squad_max_size() THEN
    RETURN jsonb_build_object('released', false, 'squad_total', v_total);
  END IF;

  v_release := public.pick_squad_overflow_release_player(v_club, p_new_player_id);

  IF v_release IS NULL THEN
    RAISE EXCEPTION
      'Permanent squad has % players (max %) but no player could be selected for overflow release',
      v_total, public.squad_max_size();
  END IF;

  SELECT coalesce(c.foreign_interest_remaining, 0)
  INTO v_interest
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF coalesce(v_interest, 0) > 0 THEN
    v_teams := public.sync_club_foreign_tracking(v_club);
    v_team := v_teams[1];
  END IF;

  IF coalesce(v_interest, 0) > 0 AND nullif(btrim(coalesce(v_team, '')), '') IS NOT NULL THEN
    v_result := public.club_release_player_foreign_overflow(v_club, v_release, v_team);
  ELSE
    v_result := public.club_release_player_mv_overflow(v_club, v_release);
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'released', true,
    'squad_total_before', v_total,
    'squad_total', public.club_permanent_squad_count(v_club)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.enforce_squad_overflow_after_signing(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enforce_squad_overflow_after_signing(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.transferengine_finalize_deferred_squad_overflow()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_total int;
  v_guard int;
BEGIN
  IF coalesce(nullif(current_setting('gpsl.defer_squad_overflow', true), ''), '') <> 'on' THEN
    RETURN;
  END IF;

  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE public.club_permanent_squad_count(c."ShortName") > public.squad_max_size()
  LOOP
    BEGIN
      v_guard := 0;
      LOOP
        v_guard := v_guard + 1;
        EXIT WHEN v_guard > 15;

        v_total := public.club_permanent_squad_count(v_club);
        EXIT WHEN v_total <= public.squad_max_size();

        BEGIN
          PERFORM public.enforce_squad_overflow_after_signing(v_club, NULL);
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'deferred overflow release failed for % (squad %): %',
            v_club, v_total, SQLERRM;
          EXIT;
        END;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'deferred overflow pass failed for %: %', v_club, SQLERRM;
    END;
  END LOOP;
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- Report (read-only): clubs over 28 and the players the rule would release,
-- in order (not-signed-this-season first, then highest rated).
WITH over AS (
  SELECT c."ShortName" AS club,
         public.club_permanent_squad_count(c."ShortName") AS squad,
         public.club_permanent_squad_count(c."ShortName") - public.squad_max_size() AS over_by,
         coalesce(c.foreign_interest_remaining, 0) AS foreign_slots
  FROM public."Clubs" c
  WHERE public.club_permanent_squad_count(c."ShortName") > public.squad_max_size()
),
ranked AS (
  SELECT o.club, o.squad, o.over_by, o.foreign_slots,
         p."Name", p."Position", p."Rating", p.market_value,
         public.player_signed_this_season(p."Season_Signed") AS signed_this_season,
         row_number() OVER (
           PARTITION BY o.club
           ORDER BY public.player_signed_this_season(p."Season_Signed"),
                    public.player_rating_as_numeric(p."Rating"::text) DESC, p."Name"
         ) AS release_order
  FROM over o
  JOIN public."Players" p ON p."Contracted_Team" = o.club
  WHERE NOT EXISTS (
    SELECT 1 FROM public.club_emergency_loans l
    JOIN public.competition_seasons s ON s.id = l.season_id AND s.is_current
    WHERE l.club_short_name = o.club AND l.status = 'active'
      AND l.player_id::text = p."Konami_ID"::text
  )
)
SELECT club, squad, over_by, foreign_slots, release_order,
       "Name" AS would_release, "Position", "Rating", market_value, signed_this_season,
       CASE WHEN release_order <= foreign_slots THEN 'foreign sale (no fine)'
            ELSE 'MV release + £10m fine' END AS method
FROM ranked
WHERE release_order <= over_by
ORDER BY club, release_order;
