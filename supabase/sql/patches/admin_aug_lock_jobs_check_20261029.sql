SELECT job_key, gpsl_month,
       to_char(timezone('Europe/London', ran_at), 'YYYY-MM-DD HH24:MI') AS ran_uk
FROM public.competition_season_calendar_jobs j
JOIN public.competition_seasons s ON s.id = j.season_id AND s.is_current
WHERE lower(coalesce(j.gpsl_month,'')) = 'august'
   OR j.ran_at >= timezone('utc', date_trunc('day', timezone('Europe/London', now())) - interval '1 day')
ORDER BY ran_at DESC
LIMIT 50;
