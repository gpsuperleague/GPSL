SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'competition_cup_bracket_nodes'
ORDER BY ordinal_position;
