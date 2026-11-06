-- owners for BES/FLA
select c.short_name, c.owner_id, o.display_name
from competition_clubs c
left join profiles o on o.id = c.owner_id
where c.short_name in ('BES','FLA');

-- strikes
select s.*, c.short_name
from competition_owner_season_strikes s
join competition_clubs c on c.owner_id = s.owner_id
where c.short_name in ('BES','FLA');

-- finance rows for noshow on this fixture
select table_name from information_schema.tables
where table_schema='public' and table_name ilike '%club%ledger%';
select table_name from information_schema.tables
where table_schema='public' and table_name ilike '%transaction%';
select table_name from information_schema.tables
where table_schema='public' and table_name ilike '%finance_event%';
