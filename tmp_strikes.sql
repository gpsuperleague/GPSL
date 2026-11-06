select column_name from information_schema.columns
where table_schema='public' and table_name='competition_owner_season_strikes'
order by ordinal_position;
