-- =============================================================================
-- "Can't set One of our own" — check one club, clear any leftover OooO / FF
-- rows for players who have left. Safe to re-run.
-- Change the club short name on the next line, then Run.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _ooo_club (club text);
TRUNCATE _ooo_club;
INSERT INTO _ooo_club VALUES ('CHANGE_ME');

-- 1) Remove OooO / FF rows for players no longer at this club
DELETE FROM public.club_squad_player_designations d
USING _ooo_club c
WHERE d.club_short_name = c.club
  AND NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = d.player_id
      AND btrim(coalesce(p."Contracted_Team", '')) = d.club_short_name
  );

-- 2) Report: what is blocking this club?
DROP TABLE IF EXISTS _ooo_report;
CREATE TEMP TABLE _ooo_report (sort int, check_name text, result text);

INSERT INTO _ooo_report
SELECT 1, 'Club', c.club FROM _ooo_club c;

INSERT INTO _ooo_report
SELECT 2, 'Edit window open for owners now?',
  CASE WHEN public.club_squad_designation_edit_window_open()
       THEN 'YES' ELSE 'NO — owners locked out until GPSL preseason / January' END;

INSERT INTO _ooo_report
SELECT 3, 'Nation has 79+ stars in GPDB pool?',
  CASE WHEN public.club_nation_has_gpdb_star(c.club)
       THEN 'YES' ELSE 'NO — Fan Favourite only for this club' END
FROM _ooo_club c;

INSERT INTO _ooo_report
SELECT 4, 'Current designation rows',
  coalesce(string_agg(
    d.designation || ': ' || coalesce(p."Name", '?') || ' (' || d.player_id || ', at '
      || coalesce(p."Contracted_Team", 'no club') || ')', ' | '),
    'none')
FROM _ooo_club c
LEFT JOIN public.club_squad_player_designations d ON d.club_short_name = c.club
LEFT JOIN public."Players" p ON p."Konami_ID"::text = d.player_id;

INSERT INTO _ooo_report
SELECT 5, 'Fan Favourite set? (blocks OooO until removed)',
  coalesce((
    SELECT 'YES — ' || coalesce(p."Name", d.player_id)
    FROM _ooo_club c
    JOIN public.club_squad_player_designations d
      ON d.club_short_name = c.club AND d.designation = 'fan_favourite'
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = d.player_id
    LIMIT 1
  ), 'no');

INSERT INTO _ooo_report
SELECT 6, 'Squad players eligible for OooO (home-grown, rated '
          || public.club_squad_star_min_rating() || '+)',
  coalesce(string_agg(p."Name" || ' (' || p."Rating" || ', ' || coalesce(p."Nation", '?') || ')',
                      ', ' ORDER BY p."Name"),
           'NONE — no home-grown ' || public.club_squad_star_min_rating() || '+ player left in squad')
FROM _ooo_club c
JOIN public."Players" p ON p."Contracted_Team" = c.club
WHERE public.club_squad_player_eligible_one_of_our_own(p."Konami_ID"::text, c.club);

INSERT INTO _ooo_report
SELECT 7, 'Leave-cleanup triggers installed',
  coalesce(string_agg(t.tgname, ', '), 'NONE')
FROM pg_trigger t
WHERE t.tgrelid = 'public."Players"'::regclass
  AND t.tgname IN ('players_drop_designation_on_leave', 'club_squad_designations_purge_player_trg');

SELECT r.check_name, r.result
FROM (SELECT 1) one
LEFT JOIN _ooo_report r ON true
ORDER BY r.sort;
