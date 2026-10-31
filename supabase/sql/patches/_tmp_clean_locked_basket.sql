-- Drop any already-tagged locked FAs from handpick baskets
DELETE FROM public.club_handpick_basket b
WHERE EXISTS (
  SELECT 1 FROM public."Players" p
  WHERE p."Konami_ID"::text = b.player_id
    AND (
      nullif(btrim(p."Contracted_Team"::text), '') IS NOT NULL
      OR coalesce(p.pesdb_unavailable, false)
      OR (
        to_regprocedure('public.player_foreign_contract_locked(text)') IS NOT NULL
        AND public.player_foreign_contract_locked(b.player_id)
      )
      OR (
        to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
        AND public.gpdb_player_is_season_excluded(b.player_id)
      )
    )
);

SELECT balance FROM public."Club_Finances" WHERE upper(club_name)='MAR';
SELECT count(*) AS mar_basket_left
FROM public.club_handpick_basket WHERE club_short_name='MAR';
