select s.strike_count, cl."ShortName" from competition_owner_season_strikes s join "Clubs" cl on cl.owner_id=s.owner_id where cl."ShortName" in ('BES','FLA');
