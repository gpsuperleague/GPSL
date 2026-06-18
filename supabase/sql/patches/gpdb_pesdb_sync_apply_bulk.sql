-- =============================================================================
-- GPDB sync apply — bulk UPDATE (fixes statement timeout on ~18k players)
-- Run in Supabase SQL editor, then retry Apply.
-- Includes numeric/text COALESCE fix for market_value / Maximum_Reserve_Price.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_sync_apply(p_dry_run boolean DEFAULT true)
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

  -- Full sync can take several minutes on large catalogs.
  PERFORM set_config('statement_timeout', '900000', true);

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
  FROM public.gpdb_pesdb_staging s
  WHERE p."Konami_ID"::text = s.konami_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

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
    coalesce(s.market_value, 5000000),
    coalesce(s.maximum_reserve_price, round(coalesce(s.market_value, 5000000) * 1.5, 0)),
    NULL,
    false
  FROM public.gpdb_pesdb_staging s
  WHERE NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = s.konami_id
  );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  SELECT count(*)::int INTO v_unchanged
  FROM public.gpdb_pesdb_sync_audit(ARRAY['unchanged']::text[], NULL, 0);

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', false,
    'staging_rows', v_staging,
    'marked_unavailable', v_marked,
    'inserted_free_agents', v_inserted,
    'updated', v_updated,
    'restored_from_legacy', v_restored,
    'unchanged', v_unchanged
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
