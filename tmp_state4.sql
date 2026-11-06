select "ShortName", owner_id from "Clubs" where "ShortName" in ('BES','FLA');

select s.*, cl."ShortName"
from competition_owner_season_strikes s
join "Clubs" cl on cl.owner_id = s.owner_id
where cl."ShortName" in ('BES','FLA');
