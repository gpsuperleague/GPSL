SELECT jsonb_build_object(
  'balance', (SELECT balance FROM public."Club_Finances" WHERE club_name = 'JUV'),
  'ledger', (
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id), '[]'::jsonb)
    FROM (
      SELECT id, entry_type, amount, description, created_at,
             metadata->>'source' AS source,
             metadata->>'starting_budget' AS starting_budget
      FROM public.competition_finance_ledger
      WHERE club_short_name = 'JUV'
      ORDER BY id
      LIMIT 20
    ) x
  ),
  'display', public.club_assignment_finance_display('JUV'),
  'expected_balance',
    public.club_auction_default_starting_balance()
    - public.club_stadium_infra_purchase_cost('JUV')
) AS report;
