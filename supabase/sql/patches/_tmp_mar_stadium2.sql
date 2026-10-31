SELECT
  c."ShortName",
  c."Capacity",
  public.club_stadium_infra_purchase_cost('MAR') AS stadium_cost,
  public.club_auction_default_starting_balance() AS starting_bal,
  f.balance AS balance_now,
  public.club_auction_default_starting_balance()
    - public.club_stadium_infra_purchase_cost('MAR') AS expected_after_takeover
FROM public."Clubs" c
LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = c."ShortName"
WHERE c."ShortName" = 'MAR';
