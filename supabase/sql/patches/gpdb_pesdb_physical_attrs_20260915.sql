-- =============================================================================
-- PESDB physical attrs: Height, Stronger Foot, Weak Foot Usage / Accuracy
-- Run in Supabase SQL Editor after redeploying gpdb-pesdb-scrape.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS "Height" smallint,
  ADD COLUMN IF NOT EXISTS "Stronger_Foot" text,
  ADD COLUMN IF NOT EXISTS "Weak_Foot_Usage" text,
  ADD COLUMN IF NOT EXISTS "Weak_Foot_Accuracy" text;

COMMENT ON COLUMN public."Players"."Height" IS 'Player height in cm (PESDB Authentic).';
COMMENT ON COLUMN public."Players"."Stronger_Foot" IS 'Left or Right (PESDB Authentic).';
COMMENT ON COLUMN public."Players"."Weak_Foot_Usage" IS 'PESDB Weak Foot Usage (e.g. Rarely).';
COMMENT ON COLUMN public."Players"."Weak_Foot_Accuracy" IS 'PESDB Weak Foot Accuracy (e.g. Medium).';

-- Soft probe for GPDB: Height must exist on gpdb_players_view (what GPDB selects),
-- not only on Players — views freeze p.* at CREATE time.
CREATE OR REPLACE FUNCTION public.gpdb_has_physical_attrs()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpdb_players_view'
      AND column_name = 'Height'
  )
  OR (
    -- Fallback if view missing: Players table only (draft / market query Players).
    NOT EXISTS (
      SELECT 1
      FROM information_schema.views
      WHERE table_schema = 'public'
        AND table_name = 'gpdb_players_view'
    )
    AND EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'Players'
        AND column_name = 'Height'
    )
  );
$$;

GRANT EXECUTE ON FUNCTION public.gpdb_has_physical_attrs() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_has_physical_attrs() TO anon;

ALTER TABLE public.gpdb_pesdb_staging
  ADD COLUMN IF NOT EXISTS height_cm smallint,
  ADD COLUMN IF NOT EXISTS stronger_foot text,
  ADD COLUMN IF NOT EXISTS weak_foot_usage text,
  ADD COLUMN IF NOT EXISTS weak_foot_accuracy text;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_staging_import(
  p_rows jsonb,
  p_replace boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_batch uuid := gen_random_uuid();
  v_inserted int := 0;
  v_new int := 0;
  v_updated int := 0;
  v_row jsonb;
  v_kid text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  IF coalesce(p_replace, true) THEN
    DELETE FROM public.gpdb_pesdb_staging WHERE true;
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_kid := btrim(coalesce(v_row->>'konami_id', v_row->>'player_id', ''));
    IF v_kid = '' THEN
      CONTINUE;
    END IF;

    IF EXISTS (SELECT 1 FROM public.gpdb_pesdb_staging s WHERE s.konami_id = v_kid) THEN
      v_updated := v_updated + 1;
    ELSE
      v_new := v_new + 1;
    END IF;

    INSERT INTO public.gpdb_pesdb_staging (
      konami_id,
      player_name,
      position,
      nationality,
      age,
      rating,
      max_level_rating,
      playing_style,
      calc_potential,
      market_value,
      maximum_reserve_price,
      height_cm,
      stronger_foot,
      weak_foot_usage,
      weak_foot_accuracy,
      sync_batch_id
    ) VALUES (
      v_kid,
      nullif(btrim(v_row->>'player_name'), ''),
      nullif(btrim(coalesce(v_row->>'position', v_row->>'Position')), ''),
      nullif(btrim(coalesce(v_row->>'nationality', v_row->>'nation')), ''),
      nullif(btrim(v_row->>'age'), '')::smallint,
      nullif(btrim(v_row->>'rating'), '')::smallint,
      nullif(btrim(coalesce(v_row->>'max_level_rating', v_row->>'potential')), '')::smallint,
      nullif(btrim(coalesce(v_row->>'playing_style', v_row->>'playstyle')), ''),
      nullif(btrim(v_row->>'calc_potential'), '')::smallint,
      nullif(btrim(v_row->>'market_value'), '')::numeric,
      nullif(btrim(v_row->>'maximum_reserve_price'), '')::numeric,
      nullif(btrim(coalesce(v_row->>'height_cm', v_row->>'Height')), '')::smallint,
      nullif(btrim(coalesce(v_row->>'stronger_foot', v_row->>'Stronger_Foot')), ''),
      nullif(btrim(coalesce(v_row->>'weak_foot_usage', v_row->>'Weak_Foot_Usage')), ''),
      nullif(btrim(coalesce(v_row->>'weak_foot_accuracy', v_row->>'Weak_Foot_Accuracy')), ''),
      v_batch
    )
    ON CONFLICT (konami_id) DO UPDATE SET
      player_name = EXCLUDED.player_name,
      position = EXCLUDED.position,
      nationality = EXCLUDED.nationality,
      age = EXCLUDED.age,
      rating = EXCLUDED.rating,
      max_level_rating = EXCLUDED.max_level_rating,
      playing_style = EXCLUDED.playing_style,
      calc_potential = EXCLUDED.calc_potential,
      market_value = EXCLUDED.market_value,
      maximum_reserve_price = EXCLUDED.maximum_reserve_price,
      height_cm = EXCLUDED.height_cm,
      stronger_foot = EXCLUDED.stronger_foot,
      weak_foot_usage = EXCLUDED.weak_foot_usage,
      weak_foot_accuracy = EXCLUDED.weak_foot_accuracy,
      loaded_at = now(),
      sync_batch_id = EXCLUDED.sync_batch_id;

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'batch_id', v_batch,
    'rows_imported', v_inserted,
    'rows_new', v_new,
    'rows_updated', v_updated,
    'staging_count', (SELECT count(*)::int FROM public.gpdb_pesdb_staging)
  );
END;
$function$;

-- Phased apply (current live signature) — include physical attrs on update + insert
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_sync_apply(
  p_dry_run boolean DEFAULT true,
  p_phase text DEFAULT NULL,
  p_batch_offset int DEFAULT 0,
  p_batch_size int DEFAULT 800
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_staging int;
  v_marked int := 0;
  v_inserted int := 0;
  v_updated int := 0;
  v_mv_only int := 0;
  v_restored int := 0;
  v_unchanged int := 0;
  v_total int := 0;
  v_batch int := 0;
  v_next int := 0;
  v_phase text := lower(nullif(btrim(p_phase), ''));
  v_limit int := greatest(coalesce(p_batch_size, 800), 1);
  v_offset int := greatest(coalesce(p_batch_offset, 0), 0);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_staging FROM public.gpdb_pesdb_staging;
  IF v_staging = 0 THEN
    RAISE EXCEPTION 'Staging table is empty — upload a PESDB scrape CSV first';
  END IF;

  IF coalesce(p_dry_run, true) THEN
    SELECT
      count(*) FILTER (WHERE action = 'mark_unavailable'),
      count(*) FILTER (WHERE action = 'insert_free_agent'),
      count(*) FILTER (WHERE action IN ('update_stats', 'restore_and_update', 'update_mv')),
      count(*) FILTER (WHERE action = 'update_mv'),
      count(*) FILTER (WHERE action = 'restore_and_update'),
      count(*) FILTER (WHERE action = 'unchanged')
    INTO v_marked, v_inserted, v_updated, v_mv_only, v_restored, v_unchanged
    FROM public.gpdb_pesdb_sync_audit();

    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', true,
      'staging_rows', v_staging,
      'would_mark_unavailable', v_marked,
      'would_insert_free_agents', v_inserted,
      'would_update', v_updated,
      'would_update_mv_only', v_mv_only,
      'would_restore_from_legacy', v_restored,
      'unchanged', v_unchanged
    );
  END IF;

  IF v_phase IS NULL THEN
    RAISE EXCEPTION 'Live apply must use phased batches: p_phase = legacy | update | insert';
  END IF;

  PERFORM set_config('statement_timeout', '120000', true);

  IF v_phase = 'legacy' THEN
    UPDATE public."Players" p
    SET
      pesdb_unavailable = true,
      pesdb_unavailable_since = coalesce(p.pesdb_unavailable_since, now())
    WHERE NOT EXISTS (
      SELECT 1 FROM public.gpdb_pesdb_staging s
      WHERE s.konami_id = p."Konami_ID"::text
    )
    AND NOT coalesce(p.pesdb_unavailable, false);

    GET DIAGNOSTICS v_marked = ROW_COUNT;

    SELECT count(*)::int INTO v_restored
    FROM public.gpdb_pesdb_staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
    WHERE coalesce(p.pesdb_unavailable, false);

    SELECT count(*)::int INTO v_total
    FROM public.gpdb_pesdb_staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id;

    SELECT count(*)::int INTO v_inserted
    FROM public.gpdb_pesdb_staging s
    WHERE NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = s.konami_id
    );

    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', false,
      'phase', 'legacy',
      'staging_rows', v_staging,
      'marked_unavailable', v_marked,
      'restored_from_legacy', v_restored,
      'total_matched', v_total,
      'total_new', v_inserted
    );
  END IF;

  IF v_phase = 'update' THEN
    SELECT count(*)::int INTO v_total
    FROM public.gpdb_pesdb_staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id;

    WITH batch AS (
      SELECT s.*
      FROM public.gpdb_pesdb_staging s
      JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
      ORDER BY s.konami_id
      LIMIT v_limit
      OFFSET v_offset
    )
    UPDATE public."Players" p
    SET
      "Name" = coalesce(s.player_name, p."Name"),
      "Position" = coalesce(s.position, p."Position"),
      "Nation" = coalesce(s.nationality, p."Nation"),
      "Age" = coalesce(s.age::text, p."Age"::text),
      "Rating" = coalesce(s.rating::text, p."Rating"::text),
      "Potential" = coalesce(s.max_level_rating::text, p."Potential"::text),
      "Calc_Potential" = coalesce(s.calc_potential::text, p."Calc_Potential"::text),
      "Playstyle" = coalesce(s.playing_style, p."Playstyle"),
      "Height" = coalesce(s.height_cm, p."Height"),
      "Stronger_Foot" = coalesce(s.stronger_foot, p."Stronger_Foot"),
      "Weak_Foot_Usage" = coalesce(s.weak_foot_usage, p."Weak_Foot_Usage"),
      "Weak_Foot_Accuracy" = coalesce(s.weak_foot_accuracy, p."Weak_Foot_Accuracy"),
      market_value = coalesce(
        s.market_value,
        nullif(btrim(p.market_value::text), '')::numeric
      ),
      "Maximum_Reserve_Price" = coalesce(
        s.maximum_reserve_price,
        nullif(btrim(p."Maximum_Reserve_Price"::text), '')::numeric
      ),
      pesdb_unavailable = false,
      pesdb_unavailable_since = NULL,
      contract_wage = CASE
        WHEN public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
         AND s.market_value IS NOT NULL THEN
          round(
            public.calculate_standard_player_wage(
              s.market_value,
              public.competition_club_division_tier(
                public.player_contracted_club_key(p."Contracted_Team")
              )
            ),
            0
          )
        ELSE p.contract_wage
      END
    FROM batch s
    WHERE p."Konami_ID"::text = s.konami_id;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_next := v_offset + v_batch;

    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', false,
      'phase', 'update',
      'staging_rows', v_staging,
      'rows_this_batch', v_batch,
      'batch_offset', v_offset,
      'next_offset', v_next,
      'total_matched', v_total,
      'has_more', v_next < v_total
    );
  END IF;

  IF v_phase = 'insert' THEN
    SELECT count(*)::int INTO v_total
    FROM public.gpdb_pesdb_staging s
    WHERE NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = s.konami_id
    );

    WITH pending AS (
      SELECT s.*
      FROM public.gpdb_pesdb_staging s
      WHERE NOT EXISTS (
        SELECT 1 FROM public."Players" p
        WHERE p."Konami_ID"::text = s.konami_id
      )
      ORDER BY s.konami_id
      LIMIT v_limit
      OFFSET v_offset
    )
    INSERT INTO public."Players" (
      "Konami_ID",
      "Name",
      "Position",
      "Nation",
      "Age",
      "Rating",
      "Potential",
      "Calc_Potential",
      "Playstyle",
      "Height",
      "Stronger_Foot",
      "Weak_Foot_Usage",
      "Weak_Foot_Accuracy",
      market_value,
      "Maximum_Reserve_Price",
      "Contracted_Team",
      pesdb_unavailable
    )
    SELECT
      s.konami_id,
      coalesce(s.player_name, 'Unknown'),
      coalesce(s.position, 'CF'),
      coalesce(s.nationality, 'Unknown'),
      coalesce(s.age::text, '25'),
      coalesce(s.rating::text, '60'),
      coalesce(s.max_level_rating::text, s.rating::text, '60'),
      coalesce(s.calc_potential::text, s.max_level_rating::text, s.rating::text, '60'),
      coalesce(s.playing_style, 'None'),
      s.height_cm,
      s.stronger_foot,
      s.weak_foot_usage,
      s.weak_foot_accuracy,
      coalesce(s.market_value, 5000000),
      coalesce(s.maximum_reserve_price, round(coalesce(s.market_value, 5000000) * 1.5, 0)),
      NULL,
      false
    FROM pending s;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_next := v_offset + v_batch;

    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', false,
      'phase', 'insert',
      'staging_rows', v_staging,
      'rows_this_batch', v_batch,
      'batch_offset', v_offset,
      'next_offset', v_next,
      'total_new', v_total,
      'has_more', v_next < v_total
    );
  END IF;

  RAISE EXCEPTION 'Unknown phase: % (use legacy | update | insert)', v_phase;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_staging_import(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_sync_apply(boolean, text, int, int) TO authenticated;

-- Career profile: include physical attrs on player object
CREATE OR REPLACE FUNCTION public.competition_player_career_bundle(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_player jsonb;
  v_stints jsonb;
  v_honours jsonb;
  v_awards jsonb;
  v_totals jsonb;
  v_transfers jsonb;
  v_discipline jsonb;
BEGIN
  SELECT to_jsonb(p)
  INTO v_player
  FROM (
    SELECT
      p."Konami_ID" AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Rating" AS rating,
      p."Nation" AS nation,
      p."Contracted_Team" AS current_club,
      p."Height" AS height_cm,
      p."Stronger_Foot" AS stronger_foot,
      p."Weak_Foot_Usage" AS weak_foot_usage,
      p."Weak_Foot_Accuracy" AS weak_foot_accuracy
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
    LIMIT 1
  ) p;

  SELECT coalesce(jsonb_agg(row_to_json(c) ORDER BY c.season_label DESC), '[]'::jsonb)
  INTO v_stints
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(h) ORDER BY h.honoured_at DESC), '[]'::jsonb)
  INTO v_honours
  FROM public.competition_player_honours_public h
  WHERE h.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(a) ORDER BY a.season_label DESC), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  WHERE a.player_id = v_pid;

  SELECT jsonb_build_object(
    'appearances', coalesce(sum(appearances), 0),
    'goals', coalesce(sum(goals), 0),
    'assists', coalesce(sum(assists), 0),
    'potm_awards', coalesce(sum(potm_awards), 0),
    'clean_sheets', coalesce(sum(clean_sheets), 0),
    'avg_rating', round(avg(avg_rating) FILTER (WHERE avg_rating IS NOT NULL), 2)
  )
  INTO v_totals
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.transfer_time DESC), '[]'::jsonb)
  INTO v_transfers
  FROM (
    SELECT
      h.player_id::text AS player_id,
      public.transfer_history_season_label(h.transfer_time) AS season_label,
      h.transfer_time,
      h.seller_club_id AS seller_club_short_name,
      h.buyer_club_id AS buyer_club_short_name,
      h.foreign_buyer_name,
      h.transfer_sale_note,
      coalesce(h.fee, 0)::numeric AS fee,
      coalesce(h.agent_fee, 0)::numeric AS agent_fee,
      (coalesce(h.fee, 0) + coalesce(h.agent_fee, 0))::numeric AS total_cost,
      CASE
        WHEN coalesce(h.fee, 0) <= 0 THEN 'free'
        WHEN h.transfer_sale_note = 'squad_overflow' THEN 'overflow_release'
        WHEN h.foreign_buyer_name IS NOT NULL AND btrim(h.foreign_buyer_name) <> '' THEN 'foreign_sale'
        ELSE 'transfer'
      END AS move_kind
    FROM public."Transfer_History" h
    WHERE h.player_id::text = v_pid
  ) t;

  SELECT coalesce(jsonb_agg(row_to_json(d) ORDER BY d.created_at DESC), '[]'::jsonb)
  INTO v_discipline
  FROM (
    SELECT
      s.id AS suspension_id,
      s.season_id,
      se.label AS season_label,
      s.club_short_name,
      s.reason,
      s.yellow_count_at_issue,
      s.ban_matches,
      s.status,
      s.source_fixture_id,
      s.created_at,
      CASE
        WHEN s.reason = 'red_card' THEN 'Red card — 2 match ban'
        WHEN s.reason = 'yellow_accumulation' THEN
          format('Yellow card accumulation (%s) — 2 match ban', coalesce(s.yellow_count_at_issue, 8))
        ELSE s.reason
      END AS summary,
      coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'fixture_id', sm.fixture_id,
            'sequence_no', sm.sequence_no,
            'served', sm.served,
            'label', public.competition_fixture_discipline_label(f, s.club_short_name)
          )
          ORDER BY sm.sequence_no
        )
        FROM public.competition_player_suspension_matches sm
        JOIN public.competition_fixtures f ON f.id = sm.fixture_id
        WHERE sm.suspension_id = s.id
      ), '[]'::jsonb) AS matches
    FROM public.competition_player_suspensions s
    LEFT JOIN public.competition_seasons se ON se.id = s.season_id
    WHERE s.player_id = v_pid
  ) d;

  RETURN jsonb_build_object(
    'player', coalesce(v_player, '{}'::jsonb),
    'stints', coalesce(v_stints, '[]'::jsonb),
    'honours', coalesce(v_honours, '[]'::jsonb),
    'awards', coalesce(v_awards, '[]'::jsonb),
    'totals', coalesce(v_totals, '{}'::jsonb),
    'transfers', coalesce(v_transfers, '[]'::jsonb),
    'discipline', coalesce(v_discipline, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_player_career_bundle(text) TO authenticated;

-- =============================================================================
-- GPDB view: p.* is expanded at CREATE time. Adding Players.Height later does
-- NOT update gpdb_players_view — recreate so Height / foot columns appear.
-- (Same definition as gpdb_market_value_numeric_filter.sql / gpdb_effective_wage_view.sql)
-- =============================================================================
DROP VIEW IF EXISTS public.gpdb_players_view;

CREATE VIEW public.gpdb_players_view
WITH (security_invoker = true) AS
SELECT
  p.*,
  COALESCE(
    NULLIF(p.contract_wage, 0),
    round(
      greatest(
        coalesce(nullif(btrim(p.market_value::text), ''), '0')::numeric,
        0
      ) * coalesce(gs.wage_pct_championship, 4::numeric) / 100.0,
      0
    )
  ) AS effective_wage,
  nullif(btrim(p.market_value::text), '')::numeric AS market_value_n
FROM public."Players" p
LEFT JOIN public.global_settings gs ON gs.id = 1;

GRANT SELECT ON public.gpdb_players_view TO authenticated;
GRANT SELECT ON public.gpdb_players_view TO anon;

NOTIFY pgrst, 'reload schema';
