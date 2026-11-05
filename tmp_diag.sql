select gpsl_month, place, club_short_name, amount, points, created_at
from public.gpsl_friendlies_prize_payouts
where season_id=1 and gpsl_month in ('august','september')
order by gpsl_month, place;

select public.competition_month_lock_side_effects_status() as status;

-- Month-lock footprints around Sep lock (19:00 UTC today)
select entry_type, count(*), min(created_at), max(created_at)
from public.competition_finance_ledger
where created_at between '2026-11-05 18:50:00+00' and '2026-11-05 20:30:00+00'
group by 1 order by 3;

select jobname, schedule, command, active
from cron.job
where command ilike '%month_lock%' or command ilike '%friendlies%' or jobname ilike '%month%'
order by jobname;
