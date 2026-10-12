-- =============================================================================
-- 34+ age fee: One of Our Own players are exempt (2026-10-12)
-- =============================================================================
-- competition_club_34plus_count is the single source for the 34+ fee (Close
-- Finances posting, wage bill previews, wage bill monitor). It now skips any
-- player designated One of Our Own at that club.
-- Safe re-run. Fees already posted this season are not changed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_club_34plus_count(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min int;
BEGIN
  -- Column name is historical; value is the minimum AGE threshold.
  v_min := (SELECT wage_34plus_min_rating FROM public.global_settings WHERE id = 1);

  RETURN (
    SELECT count(*)::int
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_club_short_name
      AND nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      AND nullif(btrim(p."Age"::text), '')::int >= coalesce(v_min, 34)
      AND NOT EXISTS (
        SELECT 1
        FROM public.club_squad_player_designations d
        WHERE d.club_short_name = btrim(p_club_short_name)
          AND d.designation = 'one_of_our_own'
          AND btrim(d.player_id::text) = p."Konami_ID"::text
      )
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_club_34plus_count(text) IS
  'Count contracted squad players aged >= global_settings.wage_34plus_min_rating (min age; column name is historical), excluding the club''s One of Our Own player.';

NOTIFY pgrst, 'reload schema';

-- Report: clubs whose OooO player is 34+ (now exempt)
SELECT
  d.club_short_name AS club,
  p."Name" AS ooo_player,
  p."Age" AS age,
  public.competition_club_34plus_count(d.club_short_name) AS players_charged_34plus
FROM public.club_squad_player_designations d
JOIN public."Players" p ON p."Konami_ID"::text = btrim(d.player_id::text)
WHERE d.designation = 'one_of_our_own'
  AND nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
  AND btrim(p."Age"::text)::int >= coalesce((SELECT wage_34plus_min_rating FROM public.global_settings WHERE id = 1), 34)
ORDER BY d.club_short_name;
