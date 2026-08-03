-- =============================================================================
-- Admin Season Expectations board
-- Club + owner + manager | expect vs actual | projected EOS consequences
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_season_expectations_board(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_season_label text;
  v_rows jsonb := '[]'::jsonb;
  v_r record;
  v_metrics jsonb;
  v_owner text;
  v_club_conseq text;
  v_mgr_conseq text;
  v_tier text;
  v_band text;
  v_miss boolean;
  v_hits int;
  v_misses int;
  v_proj_hits int;
  v_seasons_left int;
  v_target_met boolean;
  v_mgr_id bigint;
  v_mgr_name text;
  v_mgr_rating int;
  v_mgr_pending boolean;
  v_mgr_mv numeric;
  v_mgr_target_kind text;
  v_mgr_target_value int;
  v_mgr_target_label text;
  v_mgr_pos int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id, label INTO v_season_id, v_season_label
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    SELECT label INTO v_season_label
    FROM public.competition_seasons
    WHERE id = v_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'rows', '[]'::jsonb);
  END IF;

  FOR v_r IN
    SELECT
      ccs.club_short_name,
      ccs.division,
      coalesce(cl."Club", ccs.club_short_name) AS club_name,
      cl.owner_id,
      cl.manager_id
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" cl ON cl."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    ORDER BY
      CASE ccs.division
        WHEN 'superleague' THEN 1
        WHEN 'championship_a' THEN 2
        WHEN 'championship_b' THEN 3
        ELSE 9
      END,
      cl."Club"
  LOOP
    v_owner := NULL;
    BEGIN
      v_owner := public.competition_owner_display_name(v_r.owner_id);
    EXCEPTION WHEN OTHERS THEN
      v_owner := NULL;
    END;

    v_metrics := NULL;
    BEGIN
      v_metrics := public.competition_stadium_season_metrics(
        v_r.club_short_name,
        v_season_id,
        v_r.division
      );
    EXCEPTION WHEN OTHERS THEN
      v_metrics := jsonb_build_object('error', SQLERRM);
    END;

    v_tier := coalesce(
      nullif(btrim(coalesce(v_metrics ->> 'club_tier', '')), ''),
      public.competition_club_tier(v_r.club_short_name)
    );
    v_band := nullif(btrim(coalesce(v_metrics ->> 'performance_band', '')), '');
    v_miss := false;
    BEGIN
      v_miss := public.club_underperformance_missed_expectation(
        v_r.club_short_name,
        v_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      v_miss := (v_tier IN ('big', 'medium') AND v_band IS NOT NULL AND v_band <> 'on_target');
    END;

    -- Club EOS consequences (if season archived / closed today)
    IF v_metrics ? 'error' OR v_band IS NULL THEN
      v_club_conseq := 'Pending — not enough season data yet';
    ELSIF v_tier = 'low' THEN
      v_club_conseq := 'Low tier — no forced listing; stadium fill follows band only';
    ELSIF NOT v_miss THEN
      v_club_conseq := 'On target — no forced listing; stadium fill bonus path';
    ELSIF v_tier = 'big' THEN
      v_club_conseq := format(
        'Miss (%s) — forced listing: random of top-4 rated players (MV, perpetual)',
        replace(v_band, '_', ' ')
      );
    ELSIF v_tier = 'medium' THEN
      v_club_conseq := format(
        'Miss (%s) — forced listing: one 74–78 rated player aged 22+ (MV, perpetual)',
        replace(v_band, '_', ' ')
      );
    ELSE
      v_club_conseq := format('Miss (%s) — underperformance listing rules apply', replace(v_band, '_', ' '));
    END IF;

    -- Manager block
    v_mgr_conseq := 'No manager contracted';
    v_target_met := NULL;
    v_hits := 0;
    v_misses := 0;
    v_seasons_left := NULL;
    v_proj_hits := 0;
    v_mgr_id := NULL;
    v_mgr_name := NULL;
    v_mgr_rating := NULL;
    v_mgr_pending := false;
    v_mgr_mv := NULL;
    v_mgr_target_kind := NULL;
    v_mgr_target_value := NULL;
    v_mgr_target_label := NULL;
    v_mgr_pos := NULL;

    IF v_r.manager_id IS NOT NULL THEN
      SELECT
        m.id,
        m.name,
        m.rating,
        m.contract_seasons_remaining,
        coalesce(m.pending_owner_renewal, false),
        m.market_value,
        mcs.target_kind,
        mcs.target_value,
        mcs.target_label,
        mcs.target_met,
        mcs.season_position,
        coalesce(mcs.deal_target_hits, 0),
        coalesce(mcs.deal_target_misses, 0)
      INTO
        v_mgr_id,
        v_mgr_name,
        v_mgr_rating,
        v_seasons_left,
        v_mgr_pending,
        v_mgr_mv,
        v_mgr_target_kind,
        v_mgr_target_value,
        v_mgr_target_label,
        v_target_met,
        v_mgr_pos,
        v_hits,
        v_misses
      FROM public."Managers" m
      LEFT JOIN public.manager_club_status_public mcs
        ON mcs.club_short_name = v_r.club_short_name
       AND mcs.manager_id = m.id
      WHERE m.id = v_r.manager_id;

      IF v_mgr_id IS NOT NULL THEN
        v_proj_hits := v_hits + CASE WHEN v_target_met IS TRUE THEN 1 ELSE 0 END;

        IF v_mgr_pending THEN
          v_mgr_conseq := 'Awaiting owner renewal decision';
        ELSIF coalesce(v_seasons_left, 0) > 1 THEN
          v_mgr_conseq := format(
            'Mid-deal (year 1 of 2) — this season %s; then %s season left on deal',
            CASE WHEN v_target_met IS TRUE THEN 'HIT' WHEN v_target_met IS FALSE THEN 'MISS' ELSE 'pending' END,
            (v_seasons_left - 1)::text
          );
        ELSIF coalesce(v_seasons_left, 0) <= 1 THEN
          IF v_proj_hits > 0 THEN
            v_mgr_conseq := format(
              'End of deal — ≥1 target hit (projected %s hit(s)) → owner renewal offer',
              v_proj_hits
            );
          ELSE
            v_mgr_conseq := format(
              'End of deal — 0 hits projected → released for full MV (₿%s); 2-season rehire ban',
              to_char(coalesce(v_mgr_mv, 0), 'FM999,999,999')
            );
          END IF;
        END IF;
      END IF;
    END IF;

    v_rows := v_rows || jsonb_build_array(
      jsonb_build_object(
        'club_short_name', v_r.club_short_name,
        'club_name', v_r.club_name,
        'division', v_r.division,
        'owner_id', v_r.owner_id,
        'owner_name', coalesce(nullif(btrim(v_owner), ''), '—'),
        'tier', v_tier,
        'club_expected_position', CASE
          WHEN (v_metrics ->> 'expected_position') ~ '^-?\d+$'
            THEN (v_metrics ->> 'expected_position')::int
          ELSE NULL
        END,
        'club_actual_position', CASE
          WHEN (v_metrics ->> 'actual_position') ~ '^-?\d+$'
            THEN (v_metrics ->> 'actual_position')::int
          ELSE NULL
        END,
        'club_expected_points', CASE
          WHEN (v_metrics ->> 'expected_points') ~ '^-?\d+(\.\d+)?$'
            THEN (v_metrics ->> 'expected_points')::numeric
          ELSE NULL
        END,
        'club_actual_points', CASE
          WHEN (v_metrics ->> 'actual_points') ~ '^-?\d+(\.\d+)?$'
            THEN (v_metrics ->> 'actual_points')::numeric
          ELSE NULL
        END,
        'club_performance_gap', CASE
          WHEN (v_metrics ->> 'performance_gap') ~ '^-?\d+(\.\d+)?$'
            THEN (v_metrics ->> 'performance_gap')::numeric
          ELSE NULL
        END,
        'club_performance_band', v_band,
        'club_missed_expectation', v_miss,
        'club_eos_consequence', v_club_conseq,
        'manager_id', v_mgr_id,
        'manager_name', v_mgr_name,
        'manager_rating', v_mgr_rating,
        'manager_target_label', v_mgr_target_label,
        'manager_target_kind', v_mgr_target_kind,
        'manager_target_value', v_mgr_target_value,
        'manager_season_position', v_mgr_pos,
        'manager_target_met', v_target_met,
        'manager_seasons_remaining', v_seasons_left,
        'manager_deal_hits', v_hits,
        'manager_deal_misses', v_misses,
        'manager_pending_renewal', v_mgr_pending,
        'manager_eos_consequence', v_mgr_conseq
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'row_count', jsonb_array_length(v_rows),
    'rows', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_season_expectations_board(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
