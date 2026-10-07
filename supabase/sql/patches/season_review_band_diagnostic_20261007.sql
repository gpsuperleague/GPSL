-- Step 2: full Wolves metrics + the live function lines that set position / band.
SELECT 'metrics json' AS part,
       public.competition_stadium_season_metrics('WOL', 1, NULL)::text AS detail
UNION ALL
SELECT 'live function lines',
       string_agg(btrim(l), E'\n')
FROM regexp_split_to_table(
       pg_get_functiondef('public.competition_stadium_season_metrics(text,bigint,text)'::regprocedure),
       E'\n'
     ) AS l
WHERE l ~ '(v_actual_pos|v_band|RETURN|competition_club_season_standing)';
