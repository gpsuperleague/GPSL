-- Atlético (ATM) handpick: 14 wishlist players are still free agents.
-- Shows the reason the signer would refuse each one, then signs them at
-- market value in two batches (the signer allows 8 per call).
-- Anyone still refused is listed in skipped, with the reason. Nothing else moves.

WITH ids AS (
  SELECT *
  FROM (VALUES
    ('141132'), ('112015'), ('155391'), ('100428'), ('151506'), ('111928'),
    ('128057'), ('38439'), ('152198'), ('113711'), ('113760'), ('147895'),
    ('114909'), ('110695')
  ) AS t(player_id)
)
SELECT
  p."Name",
  p."Konami_ID"::text AS player_id,
  p.market_value,
  coalesce(
    nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
    0
  ) AS market_value_used,
  coalesce(p.pesdb_unavailable, false) AS legacy_card,
  public.player_club_rejoin_is_blocked(p."Konami_ID"::text, 'ATM') AS rejoin_locked,
  public.club_transfer_buy_embargo_active('ATM') AS atm_buy_embargo
FROM ids i
JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
ORDER BY p."Name";

SELECT public.admin_sign_free_agents_at_mv(
  'ATM',
  ARRAY['141132','112015','155391','100428','151506','111928','128057'],
  false
) AS batch_1;

SELECT public.admin_sign_free_agents_at_mv(
  'ATM',
  ARRAY['38439','152198','113711','113760','147895','114909','110695'],
  false
) AS batch_2;
