-- A wage negotiated above the standard stays that amount when the player
-- is sold. Super League and Championship pay the same figure.
-- A standard wage (at or under the selling club's percent of market value)
-- is recalculated for the buying club. Free-agent signings still do that,
-- because the wage was cleared on release.
-- Safe re-run.

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  PERFORM set_config('statement_timeout', '120s', true);

  v_def := replace(
    pg_get_functiondef('public.transferengine_accept_sale(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );

  IF position('Negotiated wage stays fixed across divisions' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_listing.current_highest_bidder,
    NULL::numeric,
    false
  );$old$, E'\r\n', E'\n');
  v_new := replace($new$  -- Negotiated wage stays fixed across divisions.
  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_listing.current_highest_bidder,
    CASE
      WHEN coalesce(v_player.contract_wage, 0)
        > public.calculate_player_wage_for_club(
            v_listing.player_id::text,
            v_listing.seller_club_id
          )
      THEN round(v_player.contract_wage, 0)
      ELSE NULL
    END,
    false
  );$new$, E'\r\n', E'\n');

  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'transfer sale wage needle not unique';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

SELECT position(
  'Negotiated wage stays fixed across divisions'
  IN pg_get_functiondef('public.transferengine_accept_sale(bigint)'::regprocedure)
) > 0 AS wage_kept;
