-- Future-month Club Wire propose cards still quoted the retired late fee
-- and told every home club to propose before the month opened. Cups can be
-- opened by either club once that month unlocks. League away can open after
-- the same moment. The no-proposal strike stays ₿500k on the home club.

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('avoid ₿2.5m' IN v_def) = 0 THEN
    RAISE NOTICE 'club wire propose card already updated';
    RETURN;
  END IF;

  v_old := replace($old$        'title', format('Propose vs %s (avoid ₿2.5m)', v_opp),
        'detail', CASE
          WHEN now() >= r.unlock_at - interval '48 hours' THEN
            'Late-fee window open (₿1m). No proposal by this unlock → ₿2.5m Match Management fine.'
          ELSE
            'Home must propose a kick-off before this GPSL month opens.'
        END,$old$, E'\r\n', E'\n');
  v_new := replace($new$        'title', format('Propose vs %s', v_opp),
        'detail', CASE
          WHEN lower(coalesce(r.competition_type, '')) = 'cup' THEN
            'Either club can propose once this GPSL month opens. No proposal when it locks is a strike on the home club: ₿500,000.'
          ELSE
            'Home should propose before this GPSL month opens. No proposal then is a strike on the home club: ₿500,000. After that, the away club can open it.'
        END,$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'club wire: future propose card not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$wire$;

SELECT
  position('avoid ₿2.5m' IN replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n')) = 0 AS late_fee_gone,
  position('Either club can propose once this GPSL month opens' IN replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n')) > 0 AS cup_line,
  position('After that, the away club can open it.' IN replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n')) > 0 AS league_line;
