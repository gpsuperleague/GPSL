-- =============================================================================
-- Bookies: top scorer markets — attacking players only
--
-- GK, CB, LB, RB, DMF and CMF are no longer offered in any player (scorer)
-- market. Run AFTER bookies_player_odds_shorter_20261011.sql.
--   • BEFORE INSERT trigger skips those positions when markets open/refresh
--   • Existing ones are removed; open bets on them are voided and the stake
--     refunded to the owner wallet (reversing bookies_expenditure line)
--   • Players that had bets stay as hidden 'withdrawn' rows (bets keep history)
--   • Each open/closed player market is topped back up to 40 attackers
--   • Bets on withdrawn players are blocked; markets re-priced
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_position_can_score(p_position text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT upper(btrim(coalesce(p_position, ''))) NOT IN ('GK', 'CB', 'LB', 'RB', 'DMF', 'CMF');
$function$;

CREATE OR REPLACE FUNCTION public.bookies_player_can_score(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT coalesce(
    (SELECT public.bookies_position_can_score(p."Position"::text)
     FROM public."Players" p
     WHERE p."Konami_ID"::text = btrim(coalesce(p_player_id, ''))
     LIMIT 1),
    true
  );
$function$;

-- Skip non-scoring positions whenever player markets are (re)built
CREATE OR REPLACE FUNCTION public.trg_bookies_selections_attackers_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bookies_markets m
    WHERE m.id = NEW.market_id AND m.market_kind = 'player'
  ) AND NOT public.bookies_player_can_score(NEW.selection_key) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS bookies_selections_00_attackers_only ON public.bookies_selections;
CREATE TRIGGER bookies_selections_00_attackers_only
  BEFORE INSERT ON public.bookies_selections
  FOR EACH ROW EXECUTE FUNCTION public.trg_bookies_selections_attackers_only();

-- No bets on withdrawn selections
CREATE OR REPLACE FUNCTION public.trg_bookies_bets_block_withdrawn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bookies_selections s
    WHERE s.id = NEW.selection_id
      AND coalesce((s.metadata->>'withdrawn')::boolean, false)
  ) THEN
    RAISE EXCEPTION 'That option has been withdrawn from this market';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS bookies_bets_02_block_withdrawn ON public.bookies_bets;
CREATE TRIGGER bookies_bets_02_block_withdrawn
  BEFORE INSERT ON public.bookies_bets
  FOR EACH ROW EXECUTE FUNCTION public.trg_bookies_bets_block_withdrawn();

-- Clean up existing player markets
DO $$
DECLARE
  b record;
  v_ledger bigint;
  m record;
  v_have int;
BEGIN
  -- 1) Void + refund open bets on non-scoring players
  FOR b IN
    SELECT bb.*, mk.title AS market_title, s.label AS sel_label
    FROM public.bookies_bets bb
    JOIN public.bookies_markets mk ON mk.id = bb.market_id
    JOIN public.bookies_selections s ON s.id = bb.selection_id
    WHERE mk.market_kind = 'player'
      AND bb.status = 'open'
      AND NOT public.bookies_player_can_score(s.selection_key)
    ORDER BY bb.id
    FOR UPDATE OF bb
  LOOP
    v_ledger := public._post_owner_ledger_internal(
      b.owner_id,
      'bookies_expenditure',
      abs(b.stake),
      format('Bookies bet void (player withdrawn from scorer market): %s — %s (stake ₿%s)',
             b.market_title, b.sel_label, to_char(b.stake, 'FM999999990.00')),
      jsonb_build_object(
        'bookies', true, 'bet_id', b.id, 'market_id', b.market_id,
        'refund', true, 'reason', 'non_scoring_position',
        'club_short_name', b.club_short_name
      ),
      b.season_id
    );
    UPDATE public.bookies_bets
    SET status = 'void',
        settled_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'void_reason', 'non_scoring_position',
          'refund_ledger_id', v_ledger
        )
    WHERE id = b.id;
  END LOOP;

  -- 2) Remove non-scoring selections; keep (hidden) the ones with bet history
  DELETE FROM public.bookies_selections s
  USING public.bookies_markets mk
  WHERE mk.id = s.market_id
    AND mk.market_kind = 'player'
    AND mk.status IN ('open', 'closed')
    AND NOT public.bookies_player_can_score(s.selection_key)
    AND NOT EXISTS (SELECT 1 FROM public.bookies_bets bb WHERE bb.selection_id = s.id);

  UPDATE public.bookies_selections s
  SET metadata = coalesce(s.metadata, '{}'::jsonb) || jsonb_build_object('withdrawn', true)
  FROM public.bookies_markets mk
  WHERE mk.id = s.market_id
    AND mk.market_kind = 'player'
    AND mk.status IN ('open', 'closed')
    AND NOT public.bookies_player_can_score(s.selection_key);

  -- 3) Top each player market back up to 40 attackers (by rating)
  FOR m IN
    SELECT * FROM public.bookies_markets
    WHERE market_kind = 'player' AND status IN ('open', 'closed')
  LOOP
    SELECT count(*) INTO v_have
    FROM public.bookies_selections s
    WHERE s.market_id = m.id
      AND NOT coalesce((s.metadata->>'withdrawn')::boolean, false);

    IF v_have < 40 THEN
      INSERT INTO public.bookies_selections
        (market_id, selection_key, label, odds_decimal, sort_order, weight, metadata)
      SELECT
        m.id,
        x.player_id,
        x.player_name || ' (' || x.club || ')',
        10.00,
        v_have + row_number() OVER (ORDER BY x.w DESC, x.player_name)::int,
        x.w,
        jsonb_build_object('club', x.club, 'backfill', true)
      FROM (
        SELECT
          p."Konami_ID"::text AS player_id,
          p."Name" AS player_name,
          public.player_contracted_club_key(p."Contracted_Team") AS club,
          greatest(0.5, public.bookies_player_rating_num(p."Rating"::text) / 40.0) AS w
        FROM public."Players" p
        WHERE coalesce(btrim(public.player_contracted_club_key(p."Contracted_Team")), '') <> ''
          AND EXISTS (
            SELECT 1 FROM public."Clubs" c
            WHERE c."ShortName" = public.player_contracted_club_key(p."Contracted_Team")
          )
          AND public.bookies_position_can_score(p."Position"::text)
          AND NOT EXISTS (
            SELECT 1 FROM public.bookies_selections s2
            WHERE s2.market_id = m.id AND s2.selection_key = p."Konami_ID"::text
          )
        ORDER BY w DESC, p."Name"
        LIMIT (40 - v_have)
      ) x;
    END IF;

    PERFORM public.bookies_apply_odds_from_weights(m.id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

-- Report: each player market — options now, withdrawn, and positions left
SELECT mk.title,
       count(*) FILTER (WHERE NOT coalesce((s.metadata->>'withdrawn')::boolean, false)) AS options,
       count(*) FILTER (WHERE coalesce((s.metadata->>'withdrawn')::boolean, false)) AS withdrawn,
       string_agg(DISTINCT upper(p."Position"::text), ', ')
         FILTER (WHERE NOT coalesce((s.metadata->>'withdrawn')::boolean, false)) AS positions,
       (SELECT count(*) FROM public.bookies_bets bb
        WHERE bb.market_id = mk.id AND bb.metadata->>'void_reason' = 'non_scoring_position') AS bets_refunded
FROM public.bookies_markets mk
JOIN public.bookies_selections s ON s.market_id = mk.id
LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.selection_key
WHERE mk.market_kind = 'player' AND mk.status IN ('open', 'closed')
GROUP BY mk.id, mk.title
ORDER BY mk.id;
