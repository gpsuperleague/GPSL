-- =============================================================================
-- Season Review & Projection (public, owners → Info → Season Review)
-- "If the season ended today": club expectation, board fine, transfer request,
-- manager deal outcome, projected closing balance, FFP fine + forced sales.
--
-- • season_review_finance_snapshot — projected pre-close balance per club.
--   Written by admins from the browser (owner upkeep previews are admin/own-club
--   only), via admin_season_review_publish_finance.
-- • season_review_board() — one row per league club, read-only, any signed-in user.
--
-- Mirrors (read-only, nothing is posted):
--   club_underperformance_process_club, club_underperformance_pick_player,
--   manager_process_season_end (+ cup rescue), competition_post_eos_ffp_charges.
-- Safe to re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.season_review_finance_snapshot (
  season_id bigint NOT NULL,
  club_short_name text NOT NULL,
  balance_now numeric(16, 2) NOT NULL,
  pre_close numeric(16, 2) NOT NULL,
  eos_posted boolean NOT NULL DEFAULT false,
  computed_at timestamptz NOT NULL DEFAULT now(),
  computed_by uuid,
  PRIMARY KEY (season_id, club_short_name)
);

ALTER TABLE public.season_review_finance_snapshot ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.admin_season_review_publish_finance(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  INSERT INTO public.season_review_finance_snapshot (
    season_id, club_short_name, balance_now, pre_close, eos_posted, computed_at, computed_by
  )
  SELECT
    v_season_id,
    upper(btrim(x->>'club')),
    coalesce((x->>'balance_now')::numeric, 0),
    coalesce((x->>'pre_close')::numeric, 0),
    coalesce((x->>'eos_posted')::boolean, false),
    now(),
    auth.uid()
  FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  WHERE nullif(btrim(x->>'club'), '') IS NOT NULL
  ON CONFLICT (season_id, club_short_name) DO UPDATE SET
    balance_now = excluded.balance_now,
    pre_close = excluded.pre_close,
    eos_posted = excluded.eos_posted,
    computed_at = excluded.computed_at,
    computed_by = excluded.computed_by;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'rows', v_n);
END;
$function$;

-- Candidate pool for the underperformance transfer request (same rules as
-- club_underperformance_pick_player, which picks one of these at random).
CREATE OR REPLACE FUNCTION public.season_review_listing_pool(
  p_club_short_name text,
  p_tier text,
  p_band text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_slight boolean := lower(coalesce(p_band, '')) = 'slight';
  v_rule text;
  v_pool jsonb;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _sr_squad (
    player_id text, name text, rating numeric, age numeric, top4 boolean
  ) ON COMMIT DROP;
  TRUNCATE _sr_squad;

  INSERT INTO _sr_squad
  SELECT
    q.player_id, q.name, q.rating, q.age,
    q.rk <= 4
  FROM (
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name"::text AS name,
      public.player_rating_numeric(p."Rating"::text) AS rating,
      public.player_age_numeric(p."Age"::text) AS age,
      row_number() OVER (
        ORDER BY public.player_rating_numeric(p."Rating"::text) DESC NULLS LAST, p."Konami_ID"
      ) AS rk
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
  ) q
  WHERE NOT EXISTS (
    SELECT 1 FROM public."Player_Transfer_Listings" l
    WHERE l.player_id = q.player_id
      AND l.perpetual_renew = true
      AND l.status IN ('Active', 'Review', 'Seller Review')
  );

  IF p_tier = 'big' THEN
    IF v_slight AND EXISTS (SELECT 1 FROM _sr_squad WHERE rating <= 76 AND NOT top4) THEN
      v_rule := 'One random player rated 76 or below (not one of the top 4)';
      SELECT jsonb_agg(jsonb_build_object('name', name, 'rating', rating, 'age', age) ORDER BY rating DESC, name)
      INTO v_pool FROM _sr_squad WHERE rating <= 76 AND NOT top4;
    ELSE
      v_rule := 'One random player from the top 4 rated';
      SELECT jsonb_agg(jsonb_build_object('name', name, 'rating', rating, 'age', age) ORDER BY rating DESC, name)
      INTO v_pool FROM _sr_squad WHERE top4;
    END IF;
  ELSIF p_tier = 'medium' THEN
    IF v_slight AND EXISTS (SELECT 1 FROM _sr_squad WHERE rating BETWEEN 68 AND 73 AND age > 21) THEN
      v_rule := 'One random player rated 68–73, aged 22+';
      SELECT jsonb_agg(jsonb_build_object('name', name, 'rating', rating, 'age', age) ORDER BY rating DESC, name)
      INTO v_pool FROM _sr_squad WHERE rating BETWEEN 68 AND 73 AND age > 21;
    ELSE
      v_rule := 'One random player rated 74–78, aged 22+';
      SELECT jsonb_agg(jsonb_build_object('name', name, 'rating', rating, 'age', age) ORDER BY rating DESC, name)
      INTO v_pool FROM _sr_squad WHERE rating BETWEEN 74 AND 78 AND age > 21;
    END IF;
  ELSE
    v_rule := 'One random player rated 72 or below';
    SELECT jsonb_agg(jsonb_build_object('name', name, 'rating', rating, 'age', age) ORDER BY rating DESC, name)
    INTO v_pool FROM _sr_squad WHERE rating <= 72;
  END IF;

  RETURN jsonb_build_object(
    'rule', v_rule,
    'pool', coalesce(v_pool, '[]'::jsonb),
    'pool_count', coalesce(jsonb_array_length(v_pool), 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.season_review_board()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_season_label text;
  v_rows jsonb := '[]'::jsonb;
  v_c record;
  v_metrics jsonb;
  v_tier text;
  v_band text;
  v_provisional boolean := false;
  v_cup jsonb;
  v_rescued boolean;
  v_missed boolean;
  v_expected int;
  v_club_out jsonb;
  v_mgr public."Managers"%rowtype;
  v_mgr_out jsonb;
  v_div text;
  v_pos smallint;
  v_target public.manager_rating_targets;
  v_met boolean;
  v_deal bigint;
  v_prior_n int;
  v_prior_hits int;
  v_prior_club_misses int;
  v_hits int;
  v_club_misses int;
  v_deal_seasons int;
  v_code text;
  v_text text;
  v_next text;
  v_fin jsonb;
  v_snap public.season_review_finance_snapshot%rowtype;
  v_rate numeric := 5;
  v_threshold numeric := 100000000;
  v_fine numeric := 50000000;
  v_clear numeric := 99999999;
  v_bal numeric;
  v_interest numeric;
  v_ffp boolean;
  v_releases jsonb;
  v_release_total numeric;
  v_pl record;
  v_snap_at timestamptz;
BEGIN
  IF auth.uid() IS NULL
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  SELECT id, label INTO v_season_id, v_season_label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'rows', '[]'::jsonb);
  END IF;

  SELECT
    coalesce(nullif(b.eos_debt_interest_pct, 0), nullif(b.policy_interest_rate_pct, 0), 5),
    greatest(coalesce(b.eos_ffp_debt_threshold, 100000000), 0),
    greatest(coalesce(b.eos_ffp_flat_fine, 50000000), 0),
    greatest(coalesce(b.eos_ffp_clear_threshold, 99999999), 0)
  INTO v_rate, v_threshold, v_fine, v_clear
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;
  v_rate := coalesce(v_rate, 5);
  v_threshold := coalesce(v_threshold, 100000000);
  v_fine := coalesce(v_fine, 50000000);
  v_clear := coalesce(v_clear, 99999999);

  SELECT max(computed_at) INTO v_snap_at
  FROM public.season_review_finance_snapshot
  WHERE season_id = v_season_id;

  FOR v_c IN
    SELECT
      ccs.club_short_name,
      ccs.division,
      coalesce(cl."Club", ccs.club_short_name) AS club_name,
      cl.owner_id,
      cl.manager_id,
      st.table_position,
      st.mp,
      st.pts
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" cl ON cl."ShortName" = ccs.club_short_name
    LEFT JOIN public.competition_standings_public st
      ON st.club_short_name = ccs.club_short_name
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    ORDER BY
      CASE ccs.division
        WHEN 'superleague' THEN 1
        WHEN 'championship_a' THEN 2
        ELSE 3
      END,
      st.table_position NULLS LAST,
      cl."Club"
  LOOP
    -- ---------------- Club expectation ----------------
    v_metrics := NULL;
    BEGIN
      v_metrics := public.competition_stadium_season_metrics(
        v_c.club_short_name, v_season_id, v_c.division
      );
    EXCEPTION WHEN OTHERS THEN
      v_metrics := NULL;
    END;

    v_tier := coalesce(
      nullif(btrim(coalesce(v_metrics->>'club_tier', '')), ''),
      public.competition_club_tier(v_c.club_short_name)
    );
    v_expected := CASE WHEN (v_metrics->>'expected_position') ~ '^\d+$'
                       THEN (v_metrics->>'expected_position')::int END;
    v_band := nullif(btrim(coalesce(v_metrics->>'performance_band', '')), '');
    v_provisional := false;
    -- Stadium status is hidden until the first month's league fixtures are
    -- played; the review still projects from the live table position.
    IF v_band IS NULL AND v_c.table_position IS NOT NULL AND v_expected IS NOT NULL THEN
      BEGIN
        v_band := public.club_league_expectation_band(
          v_c.club_short_name, v_season_id, v_expected, v_c.table_position, v_c.division
        );
        v_provisional := true;
      EXCEPTION WHEN OTHERS THEN
        v_band := NULL;
      END;
    END IF;
    v_band := coalesce(v_band, 'on_target');

    v_cup := NULL;
    BEGIN
      v_cup := public.club_cup_target_status(v_c.club_short_name, v_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_cup := NULL;
    END;
    v_rescued := v_band = 'slight' AND coalesce((v_cup->>'met')::boolean, false);
    v_missed := v_band <> 'on_target' AND NOT v_rescued;

    IF v_c.owner_id IS NULL THEN
      v_club_out := jsonb_build_object('code', 'vacant', 'text', 'No owner — no board fine or transfer request');
    ELSIF NOT v_missed THEN
      v_club_out := jsonb_build_object(
        'code', CASE WHEN v_rescued THEN 'cup_rescued' ELSE 'on_target' END,
        'text', CASE WHEN v_rescued
                     THEN 'Slight league miss rescued by a cup target — no board fine, no transfer request'
                     ELSE 'On target — no board fine, no transfer request' END
      );
    ELSE
      v_club_out := jsonb_build_object(
        'code', 'missed',
        'text', format('Missed expectation (%s)', replace(v_band, '_', ' ')),
        'board_fine_pct', 25,
        'listing', public.season_review_listing_pool(v_c.club_short_name, v_tier, v_band)
      );
    END IF;

    -- ---------------- Manager deal ----------------
    v_mgr_out := NULL;
    IF v_c.manager_id IS NOT NULL THEN
      SELECT * INTO v_mgr FROM public."Managers" m WHERE m.id = v_c.manager_id;
    END IF;

    IF v_c.manager_id IS NULL OR v_mgr.id IS NULL THEN
      v_mgr_out := jsonb_build_object('code', 'none', 'text', 'No manager contracted');
    ELSE
      SELECT cs.division, cs.season_position INTO v_div, v_pos
      FROM public.manager_club_season_position(v_season_id, v_c.club_short_name) cs;

      v_target := public.manager_target_for(v_mgr.rating, coalesce(v_div, v_c.division));
      v_met := NULL;
      IF v_pos IS NOT NULL THEN
        BEGIN
          v_met := public.manager_target_met_with_cup(
            v_target, v_pos, coalesce(v_div, v_c.division), v_c.club_short_name, v_season_id
          );
        EXCEPTION WHEN OTHERS THEN
          v_met := public.manager_target_met(v_target, v_pos, coalesce(v_div, v_c.division));
        END;
      END IF;

      v_deal := coalesce(v_mgr.deal_start_season_id, v_mgr.signed_season_id, v_season_id);

      SELECT
        count(*)::int,
        count(*) FILTER (WHERE r.target_met IS TRUE)::int,
        count(*) FILTER (
          WHERE public.club_expectation_missed_for_season(r.club_short_name, r.season_id)
        )::int
      INTO v_prior_n, v_prior_hits, v_prior_club_misses
      FROM public.manager_deal_season_results r
      WHERE r.manager_id = v_mgr.id
        AND r.club_short_name = v_c.club_short_name
        AND r.deal_start_season_id = v_deal
        AND r.season_id <> v_season_id;

      v_hits := coalesce(v_prior_hits, 0) + CASE WHEN v_met IS TRUE THEN 1 ELSE 0 END;
      v_club_misses := coalesce(v_prior_club_misses, 0) + CASE WHEN v_missed THEN 1 ELSE 0 END;
      v_deal_seasons := coalesce(v_prior_n, 0) + 1;
      v_next := NULL;

      IF coalesce(v_mgr.pending_owner_renewal, false)
         AND coalesce(v_mgr.contract_seasons_remaining, 0) = 0 THEN
        v_code := 'awaiting_renewal';
        v_text := 'Deal finished — waiting for the owner to renew (June/July). Not renewed by August → leaves, club gets his market value.';
      ELSIF coalesce(v_mgr.contract_seasons_remaining, 0) > 1
            AND v_band IN ('bad', 'abysmal') THEN
        v_code := 'sacked';
        v_text := format(
          'Sacked after season 1 — club is %s places below expectation (bad miss or worse). Club receives his market value (₿%s); 2-season re-hire ban.',
          greatest(coalesce(v_c.table_position, 0) - coalesce(v_expected, 0), 0),
          to_char(coalesce(v_mgr.market_value, 0), 'FM999,999,999')
        );
      ELSIF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN
        v_code := 'continues';
        v_text := format(
          'Contract continues — %s season%s left after this one.',
          v_mgr.contract_seasons_remaining - 1,
          CASE WHEN v_mgr.contract_seasons_remaining - 1 = 1 THEN '' ELSE 's' END
        );
        IF v_met IS NULL THEN
          v_next := 'This season''s target result is still pending.';
        ELSIF v_met AND NOT v_missed THEN
          v_next := 'Target hit banked and club on track — he will be open to renew when the deal ends, whatever happens next season.';
        ELSIF v_met AND v_missed THEN
          v_next := 'Target hit banked, but the club is slightly missing its expectation — if the club misses again next season, he is sacked at the end of the deal.';
        ELSIF NOT v_met AND NOT v_missed THEN
          v_next := 'No target hit yet — he must hit his target next season or he refuses a new deal and leaves.';
        ELSE
          v_next := 'No target hit and the club is slightly missing its expectation — next season he needs a target hit AND the club on target, or he leaves / is sacked.';
        END IF;
      ELSIF v_hits = 0 THEN
        v_code := 'leaves';
        v_text := format(
          'Leaves at season end — no target hit in this deal, refuses a new contract. Club receives his market value (₿%s); can''t re-sign him for 2 seasons.',
          to_char(coalesce(v_mgr.market_value, 0), 'FM999,999,999')
        );
      ELSIF v_deal_seasons >= 2 AND v_club_misses >= 2 THEN
        v_code := 'sacked';
        v_text := format(
          'Sacked at season end — club missed expectation in both seasons of the deal. Club receives his market value (₿%s); 2-season re-hire ban.',
          to_char(coalesce(v_mgr.market_value, 0), 'FM999,999,999')
        );
      ELSE
        v_code := 'renew';
        v_text := 'Open to renew — owner can offer 2 more seasons in June/July. Not renewed by August → leaves, club gets his market value.';
      END IF;

      v_mgr_out := jsonb_build_object(
        'code', v_code,
        'text', v_text,
        'next_season', v_next,
        'id', v_mgr.id,
        'name', v_mgr.name,
        'rating', v_mgr.rating,
        'market_value', v_mgr.market_value,
        'target_label', v_target.label,
        'position', v_pos,
        'target_met', v_met,
        'seasons_remaining', v_mgr.contract_seasons_remaining,
        'deal_season', v_deal_seasons,
        'deal_hits', v_hits,
        'deal_club_misses', v_club_misses,
        'pending_renewal', coalesce(v_mgr.pending_owner_renewal, false)
      );
    END IF;

    -- ---------------- Finances ----------------
    v_fin := NULL;
    v_snap := NULL;
    SELECT * INTO v_snap
    FROM public.season_review_finance_snapshot s
    WHERE s.season_id = v_season_id
      AND s.club_short_name = upper(v_c.club_short_name);

    IF v_snap.club_short_name IS NOT NULL THEN
      v_bal := v_snap.pre_close;
      v_interest := 0;
      v_ffp := false;
      v_releases := '[]'::jsonb;
      v_release_total := 0;

      IF NOT v_snap.eos_posted THEN
        IF v_bal < 0 THEN
          v_interest := round(abs(v_bal) * v_rate / 100.0);
          v_bal := v_bal - v_interest;
        END IF;
        IF v_bal <= -v_threshold THEN
          v_ffp := true;
          v_bal := v_bal - v_fine;
          FOR v_pl IN
            SELECT p."Name"::text AS pname,
                   greatest(coalesce(p.market_value::numeric, 0), 0) AS mv
            FROM public."Players" p
            WHERE public.player_contracted_club_key(p."Contracted_Team") = v_c.club_short_name
              AND greatest(coalesce(p.market_value::numeric, 0), 0) > 0
            ORDER BY greatest(coalesce(p.market_value::numeric, 0), 0) DESC, p."Konami_ID"
          LOOP
            EXIT WHEN v_bal > -v_clear;
            v_releases := v_releases || jsonb_build_array(
              jsonb_build_object('name', v_pl.pname, 'market_value', v_pl.mv)
            );
            v_release_total := v_release_total + v_pl.mv;
            v_bal := v_bal + v_pl.mv;
          END LOOP;
        END IF;
      ELSE
        v_ffp := EXISTS (
          SELECT 1 FROM public.competition_season_charge_paid cp
          WHERE cp.season_id = v_season_id
            AND cp.club_short_name = v_c.club_short_name
            AND cp.charge_type = 'eos_ffp_charge'
        );
      END IF;

      v_fin := jsonb_build_object(
        'balance_now', v_snap.balance_now,
        'pre_close', v_snap.pre_close,
        'debt_interest', v_interest,
        'ffp_fine', CASE WHEN v_ffp AND NOT v_snap.eos_posted THEN v_fine ELSE 0 END,
        'ffp', v_ffp,
        'releases', v_releases,
        'release_total', v_release_total,
        'closing', v_bal,
        'embargo', v_ffp,
        'eos_posted', v_snap.eos_posted
      );
    END IF;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'club_short_name', v_c.club_short_name,
      'club_name', v_c.club_name,
      'division', v_c.division,
      'position', v_c.table_position,
      'played', v_c.mp,
      'points', v_c.pts,
      'owner_name', CASE WHEN v_c.owner_id IS NULL THEN NULL
                         ELSE public.competition_owner_display_name(v_c.owner_id) END,
      'tier', v_tier,
      'expected_position', v_expected,
      'expectation_label', public.competition_club_expectation_label(v_expected::smallint),
      'band', v_band,
      'band_provisional', v_provisional,
      'cup_targets', coalesce(v_cup->'targets', '[]'::jsonb),
      'cup_rescued', v_rescued,
      'club_missed', v_missed,
      'club', v_club_out,
      'manager', v_mgr_out,
      'finance', v_fin
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'finance_computed_at', v_snap_at,
    'ffp_threshold', v_threshold,
    'ffp_fine', v_fine,
    'ffp_clear', v_clear,
    'debt_interest_pct', v_rate,
    'rows', v_rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.season_review_listing_pool(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.season_review_board() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_season_review_publish_finance(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Check
SELECT jsonb_array_length(public.season_review_board()->'rows') AS clubs;
