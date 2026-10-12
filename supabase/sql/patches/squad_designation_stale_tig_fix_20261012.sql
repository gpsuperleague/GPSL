-- =============================================================================
-- TIG: OooO set, player released without unsetting → no OooO / FF option
-- (2026-10-12)
-- =============================================================================
-- A leftover designation row for a player who has left the club makes the
-- squad page think the club still has an OooO, which hides both
-- "Set as One of our own" and "Set as Fan Favourite".
--   1) Delete every leftover row (any club) whose player is no longer there.
--   2) Make sure the release trigger that clears it is installed.
-- Report: TIG's rows before/after, trigger present, window open, GPSL month.
-- Safe re-run.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _desig_before ON COMMIT PRESERVE ROWS AS
SELECT d.club_short_name, d.player_id, d.designation,
       p."Name" AS player_name,
       nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '') AS player_now_at
FROM public.club_squad_player_designations d
LEFT JOIN public."Players" p ON p."Konami_ID"::text = d.player_id
WHERE false;
TRUNCATE _desig_before;

INSERT INTO _desig_before
SELECT d.club_short_name, d.player_id, d.designation,
       p."Name",
       nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '')
FROM public.club_squad_player_designations d
LEFT JOIN public."Players" p ON p."Konami_ID"::text = d.player_id
WHERE p."Konami_ID" IS NULL
   OR p."Contracted_Team" IS DISTINCT FROM d.club_short_name
   OR d.club_short_name = 'TIG';

-- 1) Leftovers
DELETE FROM public.club_squad_player_designations d
WHERE NOT EXISTS (
  SELECT 1 FROM public."Players" p
  WHERE p."Konami_ID"::text = d.player_id
    AND p."Contracted_Team" = d.club_short_name
);

-- 2) Clear on leave
CREATE OR REPLACE FUNCTION public.club_squad_designation_drop_on_leave()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  DELETE FROM public.club_squad_player_designations
  WHERE player_id = OLD."Konami_ID"::text
    AND club_short_name = OLD."Contracted_Team";
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS players_drop_designation_on_leave ON public."Players";
CREATE TRIGGER players_drop_designation_on_leave
  AFTER UPDATE OF "Contracted_Team" ON public."Players"
  FOR EACH ROW
  WHEN (OLD."Contracted_Team" IS DISTINCT FROM NEW."Contracted_Team")
  EXECUTE FUNCTION public.club_squad_designation_drop_on_leave();

NOTIFY pgrst, 'reload schema';

SELECT 'before' AS stage, b.club_short_name AS club, b.designation, b.player_name, b.player_id,
       coalesce(b.player_now_at, 'free agent / gone') AS player_now_at,
       CASE WHEN b.player_now_at IS DISTINCT FROM b.club_short_name THEN 'LEFTOVER (removed)' ELSE 'valid' END AS note
FROM _desig_before b
UNION ALL
SELECT 'after', d.club_short_name, d.designation, p."Name", d.player_id,
       coalesce(nullif(btrim(p."Contracted_Team"::text), ''), 'free agent / gone'), 'still set'
FROM public.club_squad_player_designations d
LEFT JOIN public."Players" p ON p."Konami_ID"::text = d.player_id
WHERE d.club_short_name = 'TIG'
UNION ALL
SELECT 'check', 'TIG',
       'window_open=' || public.club_squad_designation_edit_window_open()::text,
       'nation 79+ pool=' || public.club_nation_has_gpdb_star('TIG')::text,
       NULL, NULL, NULL
ORDER BY 1 DESC, 2;
