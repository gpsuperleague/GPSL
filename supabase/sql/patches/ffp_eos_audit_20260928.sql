-- =============================================================================
-- FFP end-of-season audit (READ ONLY — changes nothing)
--
-- Rebuilds each FFP club's Close Finances run from the ledger and the
-- eos_ffp_charge record, and checks it against the FFP rules:
--   1) Trigger: balance at FFP step (after wages, maintenance, debt interest)
--      was at/below −threshold (default −₿100M)
--   2) Fine: flat fine (default ₿50M) posted
--   3) Releases: highest market value first, only while balance was still
--      at/below −clear threshold (default −₿99,999,999); stop once above
--   4) Release chain matches the ledger (nothing else moved the balance)
--   5) Later re-settles (league prize / wage re-settle) — would the club still
--      have triggered, and how many releases would the rules have needed
--   6) Balance now vs balance after FFP + every ledger row since (drift)
--
-- Run this file once, then run the SELECTs at the bottom one at a time
-- (the SQL editor only shows the last result).
-- =============================================================================

-- Match clubs by ShortName or full name (spaces act as wildcards).
CREATE OR REPLACE FUNCTION public.competition_ffp_audit_clubs(
  p_season_id bigint,
  p_clubs text[]
)
RETURNS TABLE (club_short_name text, club_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT c."ShortName"::text, c."Club"::text
  FROM public."Clubs" c
  WHERE p_clubs IS NULL
     OR EXISTS (
       SELECT 1
       FROM unnest(p_clubs) q(term)
       WHERE upper(c."ShortName"::text) = upper(btrim(q.term))
          OR c."Club"::text ILIKE '%' || replace(btrim(q.term), ' ', '%') || '%'
     );
$$;

-- ---------------------------------------------------------------------------
-- Summary: one row per club
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_ffp_audit(
  p_season_id bigint DEFAULT NULL,
  p_clubs text[] DEFAULT NULL
)
RETURNS TABLE (
  club_short_name text,
  club_name text,
  division text,
  balance_before_close numeric,
  ffp_balance_snapshot numeric,
  threshold numeric,
  trigger_ok boolean,
  fine numeric,
  balance_after_fine numeric,
  clear_threshold numeric,
  releases_count int,
  releases_total numeric,
  balance_after_releases numeric,
  release_order_ok boolean,
  each_release_needed boolean,
  chain_matches_ledger boolean,
  overshoot_above_clear numeric,
  resettle_adjustment numeric,
  adjusted_ffp_balance numeric,
  would_still_trigger boolean,
  releases_needed_now int,
  players_over_released int,
  embargo_phase text,
  rejoin_blocks int,
  balance_now numeric,
  ledger_drift numeric,
  verdict text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_club record;
  v_charge record;
  v_ffp_row record;
  v_rel jsonb;
  v_prev_after numeric;
  v_prev_fee numeric;
  v_before numeric;
  v_fee numeric;
  v_after numeric;
  v_order_ok boolean;
  v_needed_ok boolean;
  v_chain_ok boolean;
  v_sim numeric;
  v_sim_n int;
  v_i int;
  v_ledger_after numeric;
  v_open numeric;
  v_since numeric;
  v_notes text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  FOR v_club IN
    SELECT a.club_short_name, a.club_name
    FROM public.competition_ffp_audit_clubs(v_season_id, p_clubs) a
    ORDER BY a.club_short_name
  LOOP
    division := NULL; balance_before_close := NULL; ffp_balance_snapshot := NULL;
    threshold := NULL; trigger_ok := NULL; fine := NULL; balance_after_fine := NULL;
    clear_threshold := NULL; releases_count := NULL; releases_total := NULL;
    balance_after_releases := NULL; release_order_ok := NULL; each_release_needed := NULL;
    chain_matches_ledger := NULL; overshoot_above_clear := NULL; resettle_adjustment := NULL;
    adjusted_ffp_balance := NULL; would_still_trigger := NULL; releases_needed_now := NULL;
    players_over_released := NULL; embargo_phase := NULL; rejoin_blocks := NULL;
    balance_now := NULL; ledger_drift := NULL; verdict := NULL;

    SELECT cp.*
    INTO v_charge
    FROM public.competition_season_charge_paid cp
    WHERE cp.season_id = v_season_id
      AND cp.club_short_name = v_club.club_short_name
      AND cp.charge_type = 'eos_ffp_charge';

    IF NOT FOUND THEN
      IF p_clubs IS NOT NULL THEN
        club_short_name := v_club.club_short_name;
        club_name := v_club.club_name;
        verdict := 'No FFP charge recorded this season';
        RETURN NEXT;
      END IF;
      CONTINUE;
    END IF;

    v_notes := ARRAY[]::text[];

    club_short_name := v_club.club_short_name;
    club_name := v_club.club_name;

    SELECT ccs.division INTO division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = v_club.club_short_name;

    ffp_balance_snapshot := (v_charge.metadata ->> 'balance_snapshot')::numeric;
    threshold := coalesce((v_charge.metadata ->> 'threshold')::numeric, 100000000);
    fine := coalesce((v_charge.metadata ->> 'flat_fine')::numeric, v_charge.amount, 0);
    clear_threshold := coalesce((v_charge.metadata ->> 'clear_threshold')::numeric, 99999999);
    trigger_ok := ffp_balance_snapshot IS NOT NULL AND ffp_balance_snapshot <= -threshold;
    balance_after_fine := ffp_balance_snapshot - fine;
    releases_count := coalesce(jsonb_array_length(v_charge.metadata -> 'releases'), 0);
    balance_after_releases := (v_charge.metadata ->> 'balance_after')::numeric;
    embargo_phase := v_charge.metadata ->> 'embargo_phase';

    IF NOT trigger_ok THEN
      v_notes := array_append(v_notes, 'Snapshot was ABOVE the trigger — fine should not have posted'::text);
    END IF;

    -- Release chain from the FFP record
    releases_total := 0;
    v_order_ok := true;
    v_needed_ok := true;
    v_chain_ok := true;
    v_prev_after := balance_after_fine;
    v_prev_fee := NULL;
    v_i := 0;

    FOR v_rel IN
      SELECT r FROM jsonb_array_elements(coalesce(v_charge.metadata -> 'releases', '[]'::jsonb)) r
    LOOP
      v_i := v_i + 1;
      v_fee := coalesce((v_rel ->> 'fee')::numeric, 0);
      v_after := (v_rel ->> 'balance_after')::numeric;
      v_before := v_after - v_fee;
      releases_total := releases_total + v_fee;

      IF v_prev_fee IS NOT NULL AND v_fee > v_prev_fee THEN
        v_order_ok := false;
      END IF;
      IF v_before > -clear_threshold THEN
        v_needed_ok := false;
      END IF;
      IF v_prev_after IS NOT NULL AND abs(v_before - v_prev_after) >= 1 THEN
        v_chain_ok := false;
      END IF;

      v_prev_after := v_after;
      v_prev_fee := v_fee;
    END LOOP;

    release_order_ok := v_order_ok;
    each_release_needed := v_needed_ok;
    overshoot_above_clear := CASE
      WHEN balance_after_releases IS NULL THEN NULL
      ELSE balance_after_releases + clear_threshold
    END;

    IF NOT v_order_ok THEN
      v_notes := array_append(v_notes, 'A cheaper player was released before a dearer one'::text);
    END IF;
    IF NOT v_needed_ok THEN
      v_notes := array_append(v_notes, 'A release happened after the balance was already clear'::text);
    END IF;
    IF balance_after_releases IS NOT NULL AND balance_after_releases <= -clear_threshold THEN
      v_notes := array_append(v_notes, 'Still at/below clear line after releases (ran out of players with MV?)'::text);
    END IF;

    -- Ledger reconstruction around the FFP fine row
    SELECT l.id, l.created_at
    INTO v_ffp_row
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_season_id
      AND l.club_short_name = v_club.club_short_name
      AND l.entry_type = 'eos_ffp_charge'
      AND coalesce(l.metadata ->> 'resettle', '') <> 'true'
    ORDER BY l.id
    LIMIT 1;

    IF FOUND THEN
      -- Opening balance before this Close Finances run
      SELECT balance_after_fine - coalesce(sum(l.amount), 0)
      INTO v_open
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club.club_short_name
        AND l.created_at = v_ffp_row.created_at
        AND l.id <= v_ffp_row.id;
      balance_before_close := v_open;

      -- Release rows posted by FFP must line up with the metadata chain
      SELECT balance_after_fine + coalesce(sum(l.amount), 0)
      INTO v_ledger_after
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club.club_short_name
        AND l.created_at = v_ffp_row.created_at
        AND l.id > v_ffp_row.id
        AND l.entry_type = 'transfer_foreign_sale'
        AND l.metadata ->> 'transfer_sale_note' = 'ffp_eos_release';

      IF balance_after_releases IS NOT NULL AND abs(v_ledger_after - balance_after_releases) >= 1 THEN
        v_chain_ok := false;
      END IF;

      -- Everything after the last FFP release, any season
      SELECT coalesce(sum(l.amount), 0)
      INTO v_since
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club.club_short_name
        AND (
          l.id > v_ffp_row.id
          AND NOT (
            l.created_at = v_ffp_row.created_at
            AND l.entry_type = 'transfer_foreign_sale'
            AND l.metadata ->> 'transfer_sale_note' = 'ffp_eos_release'
          )
        );

      SELECT f.balance INTO balance_now
      FROM public."Club_Finances" f
      WHERE f.club_name = v_club.club_short_name;

      ledger_drift := balance_now - (coalesce(balance_after_releases, balance_after_fine) + v_since);
      IF abs(ledger_drift) >= 1 THEN
        v_notes := array_append(
          v_notes,
          format('Balance now differs from ledger by ₿%s (direct balance edits?)', to_char(ledger_drift, 'FM999,999,999,999'))
        );
      END IF;
    ELSE
      v_notes := array_append(v_notes, 'No FFP ledger row found (fine ₿0?) — chain not checked'::text);
    END IF;

    chain_matches_ledger := v_chain_ok;
    IF NOT v_chain_ok THEN
      v_notes := array_append(v_notes, 'Release balances do not line up with the ledger'::text);
    END IF;

    -- Later re-settles that land before the FFP step (not balance interest)
    SELECT coalesce(sum(l.amount), 0)
    INTO resettle_adjustment
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_season_id
      AND l.club_short_name = v_club.club_short_name
      AND l.metadata ->> 'resettle' = 'true'
      AND l.entry_type <> 'eos_balance_interest';

    adjusted_ffp_balance := ffp_balance_snapshot + resettle_adjustment;
    would_still_trigger := adjusted_ffp_balance <= -threshold;

    IF NOT would_still_trigger THEN
      releases_needed_now := 0;
      v_notes := array_append(
        v_notes,
        'After re-settles the club would NOT have triggered FFP — fine + releases would not apply'::text
      );
    ELSE
      v_sim := adjusted_ffp_balance - fine;
      v_sim_n := 0;
      FOR v_rel IN
        SELECT r FROM jsonb_array_elements(coalesce(v_charge.metadata -> 'releases', '[]'::jsonb)) r
      LOOP
        EXIT WHEN v_sim > -clear_threshold;
        v_sim := v_sim + coalesce((v_rel ->> 'fee')::numeric, 0);
        v_sim_n := v_sim_n + 1;
      END LOOP;
      releases_needed_now := v_sim_n;
    END IF;

    players_over_released := greatest(releases_count - releases_needed_now, 0);
    IF players_over_released > 0 AND would_still_trigger THEN
      v_notes := array_append(
        v_notes,
        format('After re-settles only %s release(s) would be needed', releases_needed_now)
      );
    END IF;

    SELECT count(*)::int INTO rejoin_blocks
    FROM public.player_club_rejoin_blocks b
    WHERE b.club_short_name = v_club.club_short_name
      AND b.released_season_id = v_season_id
      AND b.reason = 'ffp_eos_release';

    IF rejoin_blocks <> releases_count THEN
      v_notes := array_append(
        v_notes,
        format('%s rejoin lock(s) vs %s release(s)', rejoin_blocks, releases_count)
      );
    END IF;

    verdict := CASE
      WHEN cardinality(v_notes) = 0 THEN 'OK — trigger, fine and releases follow the rules'
      ELSE array_to_string(v_notes, ' | ')
    END;

    RETURN NEXT;
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Timeline: every Close Finances step + later rows, with running balance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_ffp_audit_steps(
  p_season_id bigint DEFAULT NULL,
  p_clubs text[] DEFAULT NULL
)
RETURNS TABLE (
  club_short_name text,
  step int,
  ledger_id bigint,
  posted_at timestamptz,
  entry_type text,
  amount numeric,
  balance_after numeric,
  description text,
  player_now_at text,
  player_mv_now numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  RETURN QUERY
  WITH clubs AS (
    SELECT a.club_short_name
    FROM public.competition_ffp_audit_clubs(v_season_id, p_clubs) a
  ),
  ffp AS (
    SELECT DISTINCT ON (l.club_short_name)
      l.club_short_name,
      l.id AS ffp_id,
      l.created_at AS ffp_at,
      (cp.metadata ->> 'balance_snapshot')::numeric
        - coalesce((cp.metadata ->> 'flat_fine')::numeric, cp.amount) AS after_fine
    FROM public.competition_finance_ledger l
    JOIN clubs c ON c.club_short_name = l.club_short_name
    JOIN public.competition_season_charge_paid cp
      ON cp.season_id = v_season_id
     AND cp.club_short_name = l.club_short_name
     AND cp.charge_type = 'eos_ffp_charge'
    WHERE l.season_id = v_season_id
      AND l.entry_type = 'eos_ffp_charge'
      AND coalesce(l.metadata ->> 'resettle', '') <> 'true'
    ORDER BY l.club_short_name, l.id
  ),
  ledger_rows AS (
    SELECT
      l.id,
      l.club_short_name,
      l.created_at,
      l.entry_type,
      l.amount,
      l.description,
      l.metadata,
      f.ffp_id,
      f.after_fine
    FROM public.competition_finance_ledger l
    JOIN ffp f ON f.club_short_name = l.club_short_name
    WHERE l.created_at = f.ffp_at
       OR (l.season_id = v_season_id AND l.id > f.ffp_id)
  ),
  running AS (
    SELECT
      r.*,
      r.after_fine
        + sum(r.amount) OVER (PARTITION BY r.club_short_name ORDER BY r.id)
        - sum(CASE WHEN r.id <= r.ffp_id THEN r.amount ELSE 0 END)
            OVER (PARTITION BY r.club_short_name) AS bal_after
    FROM ledger_rows r
  )
  SELECT
    ru.club_short_name::text,
    (row_number() OVER (PARTITION BY ru.club_short_name ORDER BY ru.id))::int,
    ru.id,
    ru.created_at,
    ru.entry_type::text,
    ru.amount,
    ru.bal_after,
    ru.description::text,
    p."Contracted_Team"::text,
    p.market_value::numeric
  FROM running ru
  LEFT JOIN public."Players" p
    ON ru.metadata ? 'player_id'
   AND p."Konami_ID"::text = ru.metadata ->> 'player_id'
  ORDER BY ru.club_short_name, ru.id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_ffp_audit_clubs(bigint, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_ffp_audit(bigint, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_ffp_audit_steps(bigint, text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Run these one at a time:
--
-- 1) Summary per club (verdict column says what, if anything, looks wrong)
-- SELECT * FROM public.competition_admin_ffp_audit(
--   NULL, ARRAY['juventus', 'man city', 'lyon', 'flamengo', 'monaco']
-- );
--
-- 2) Step-by-step: wages → maintenance → debt interest → FFP fine →
--    each release → balance interest → later re-settles, with running balance
-- SELECT * FROM public.competition_admin_ffp_audit_steps(
--   NULL, ARRAY['juventus', 'man city', 'lyon', 'flamengo', 'monaco']
-- );
--
-- 3) All FFP clubs this season (in case another club should be in the list)
-- SELECT * FROM public.competition_admin_ffp_audit(NULL, NULL);
--
-- 4) Clubs NOT fined whose balance at the FFP step was at/below the trigger
-- SELECT cp.club_short_name,
--        (cp.metadata ->> 'balance_snapshot')::numeric AS debt_interest_snapshot
-- FROM public.competition_season_charge_paid cp
-- WHERE cp.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
--   AND cp.charge_type = 'eos_debt_interest'
--   AND NOT EXISTS (
--     SELECT 1 FROM public.competition_season_charge_paid f
--     WHERE f.season_id = cp.season_id
--       AND f.club_short_name = cp.club_short_name
--       AND f.charge_type = 'eos_ffp_charge'
--   )
--   AND (cp.metadata ->> 'balance_snapshot')::numeric
--       - cp.amount <= -(SELECT eos_ffp_debt_threshold FROM public.gpsl_bank_account WHERE id = 1)
-- ORDER BY 2;
-- =============================================================================
