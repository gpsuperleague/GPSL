-- =============================================================================
-- Apply the squad-over-28 rule NOW to every club over the limit (e.g. ACM 31)
-- Run AFTER squad_overflow_enforce_fix_20261011.sql.
--
-- Per the rule: release one player at a time until the permanent squad is 28
-- (not-signed-this-season first, then highest rated). Foreign sale while the
-- club has foreign slots (no fine); otherwise MV release + £10m fine.
-- Each club is done in its own sub-transaction, so one failure doesn't undo
-- the others. Safe re-run (does nothing once everyone is at 28 or under).
-- =============================================================================

DO $$
DECLARE
  v_club text;
  v_guard int;
BEGIN
  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE public.club_permanent_squad_count(c."ShortName") > public.squad_max_size()
    ORDER BY c."ShortName"
  LOOP
    BEGIN
      v_guard := 0;
      WHILE public.club_permanent_squad_count(v_club) > public.squad_max_size()
            AND v_guard < 15 LOOP
        v_guard := v_guard + 1;
        PERFORM public.enforce_squad_overflow_after_signing(v_club, NULL);
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Overflow release failed for %: %', v_club, SQLERRM;
    END;
  END LOOP;
END $$;

-- Report: overflow releases made in the last 10 minutes, plus squad size now
SELECT th.seller_club_id AS club,
       p."Name" AS player,
       p."Position",
       p."Rating",
       th.fee AS credited,
       th.foreign_buyer_name AS sold_to,
       th.transfer_sale_note,
       public.club_permanent_squad_count(th.seller_club_id) AS squad_now,
       th.transfer_time AT TIME ZONE 'Europe/London' AS at_uk
FROM public."Transfer_History" th
LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
WHERE th.transfer_time > now() - interval '10 minutes'
  AND (th.transfer_sale_note ILIKE '%overflow%' OR th.foreign_buyer_name ILIKE '%squad over 28%'
       OR th.buyer_club_id = 'FOREIGN')
ORDER BY th.seller_club_id, th.transfer_time;
