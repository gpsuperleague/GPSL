select job_key, gpsl_month, ran_at, left(result::text, 200) as result_snip
from competition_season_calendar_jobs
where season_id=1 and job_key like 'month_lock_on_calendar%'
order by ran_at desc nulls last;

select public.gpsl_month_lock_on_calendar_tick() as tick;
