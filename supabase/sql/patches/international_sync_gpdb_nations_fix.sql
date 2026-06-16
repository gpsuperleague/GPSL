-- =============================================================================
-- Fix GPDB nation sync (code RU1 / catalog alias gaps)
-- Run once, then:
--   SELECT public.international_sync_gpdb_nations();
--   SELECT public.international_refresh_gpdb_label_map();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_catalog_add_aliases(
  p_code text,
  p_aliases text[]
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  UPDATE public.international_nation_catalog c
  SET aliases = (
    SELECT coalesce(array_agg(DISTINCT a ORDER BY a), '{}'::text[])
    FROM (
      SELECT unnest(c.aliases) AS a
      UNION
      SELECT unnest(p_aliases) AS a
    ) x
  )
  WHERE c.code = upper(btrim(p_code));
END;
$function$;

-- Exact eFootball / GPDB Players.Nation spellings (audit query 4)
SELECT public.international_catalog_add_aliases('THA', ARRAY['Thailand']);
SELECT public.international_catalog_add_aliases('CIV', ARRAY['Côte d''Ivoire']);
SELECT public.international_catalog_add_aliases('ARE', ARRAY['United Arab Emirates']);
SELECT public.international_catalog_add_aliases('MLI', ARRAY['Mali']);
SELECT public.international_catalog_add_aliases('UZB', ARRAY['Uzbekistan']);
SELECT public.international_catalog_add_aliases('JOR', ARRAY['Jordan']);
SELECT public.international_catalog_add_aliases('IND', ARRAY['India']);
SELECT public.international_catalog_add_aliases('MYS', ARRAY['Malaysia']);
SELECT public.international_catalog_add_aliases('TKM', ARRAY['Turkmenistan']);
SELECT public.international_catalog_add_aliases('COD', ARRAY['Congo DR']);
SELECT public.international_catalog_add_aliases('IDN', ARRAY['Indonesia']);
SELECT public.international_catalog_add_aliases('BHR', ARRAY['Bahrain']);
SELECT public.international_catalog_add_aliases('GRE', ARRAY['Greece']);
SELECT public.international_catalog_add_aliases('ALB', ARRAY['Albania']);
SELECT public.international_catalog_add_aliases('SGP', ARRAY['Singapore']);
SELECT public.international_catalog_add_aliases('HKG', ARRAY['Hong Kong, China']);
SELECT public.international_catalog_add_aliases('VIE', ARRAY['Vietnam']);
SELECT public.international_catalog_add_aliases('SVN', ARRAY['Slovenia']);
SELECT public.international_catalog_add_aliases('ISR', ARRAY['Israel']);
SELECT public.international_catalog_add_aliases('ZWE', ARRAY['Zimbabwe']);
SELECT public.international_catalog_add_aliases('AGO', ARRAY['Angola']);
SELECT public.international_catalog_add_aliases('BGR', ARRAY['Bulgaria']);
SELECT public.international_catalog_add_aliases('GAB', ARRAY['Gabon']);
SELECT public.international_catalog_add_aliases('GIN', ARRAY['Guinea']);
SELECT public.international_catalog_add_aliases('PHL', ARRAY['Philippines']);
SELECT public.international_catalog_add_aliases('BWA', ARRAY['Botswana']);
SELECT public.international_catalog_add_aliases('BFA', ARRAY['Burkina Faso']);
SELECT public.international_catalog_add_aliases('MNE', ARRAY['Montenegro']);
SELECT public.international_catalog_add_aliases('BIH', ARRAY['Bosnia and Herzegovina']);
SELECT public.international_catalog_add_aliases('NIR', ARRAY['Northern Ireland']);
SELECT public.international_catalog_add_aliases('UGA', ARRAY['Uganda']);
SELECT public.international_catalog_add_aliases('HND', ARRAY['Honduras']);
SELECT public.international_catalog_add_aliases('ISL', ARRAY['Iceland']);
SELECT public.international_catalog_add_aliases('CYP', ARRAY['Cyprus']);
SELECT public.international_catalog_add_aliases('KOS', ARRAY['Kosovo']);
SELECT public.international_catalog_add_aliases('MKD', ARRAY['North Macedonia']);
SELECT public.international_catalog_add_aliases('SDN', ARRAY['Sudan']);
SELECT public.international_catalog_add_aliases('ZMB', ARRAY['Zambia']);
SELECT public.international_catalog_add_aliases('BEN', ARRAY['Benin']);
SELECT public.international_catalog_add_aliases('COM', ARRAY['Comoros']);
SELECT public.international_catalog_add_aliases('GNQ', ARRAY['Equatorial Guinea']);
SELECT public.international_catalog_add_aliases('GTM', ARRAY['Guatemala']);
SELECT public.international_catalog_add_aliases('KEN', ARRAY['Kenya']);
SELECT public.international_catalog_add_aliases('TAN', ARRAY['Tanzania']);
SELECT public.international_catalog_add_aliases('MOZ', ARRAY['Mozambique']);
SELECT public.international_catalog_add_aliases('GEO', ARRAY['Georgia']);
SELECT public.international_catalog_add_aliases('MLT', ARRAY['Malta']);
SELECT public.international_catalog_add_aliases('PLE', ARRAY['Palestine']);
SELECT public.international_catalog_add_aliases('GMB', ARRAY['The Gambia']);
SELECT public.international_catalog_add_aliases('CUW', ARRAY['Curaçao']);
SELECT public.international_catalog_add_aliases('PRK', ARRAY['Korea DPR']);
SELECT public.international_catalog_add_aliases('OMN', ARRAY['Oman']);
SELECT public.international_catalog_add_aliases('KWT', ARRAY['Kuwait']);
SELECT public.international_catalog_add_aliases('SUR', ARRAY['Suriname']);
SELECT public.international_catalog_add_aliases('HTI', ARRAY['Haiti']);
SELECT public.international_catalog_add_aliases('CPV', ARRAY['Cabo Verde']);
SELECT public.international_catalog_add_aliases('GNB', ARRAY['Guinea-Bissau']);
SELECT public.international_catalog_add_aliases('TJK', ARRAY['Tajikistan']);
SELECT public.international_catalog_add_aliases('RUS', ARRAY['Russia']);
SELECT public.international_catalog_add_aliases('SYR', ARRAY['Syria']);
SELECT public.international_catalog_add_aliases('TGO', ARRAY['Togo']);
SELECT public.international_catalog_add_aliases('CGO', ARRAY['Congo']);
SELECT public.international_catalog_add_aliases('TTO', ARRAY['Trinidad and Tobago']);
SELECT public.international_catalog_add_aliases('SLV', ARRAY['El Salvador']);
SELECT public.international_catalog_add_aliases('SLE', ARRAY['Sierra Leone']);
SELECT public.international_catalog_add_aliases('DOM', ARRAY['Dominican Republic']);
SELECT public.international_catalog_add_aliases('LTU', ARRAY['Lithuania']);
SELECT public.international_catalog_add_aliases('MDG', ARRAY['Madagascar']);
SELECT public.international_catalog_add_aliases('MRT', ARRAY['Mauritania']);
SELECT public.international_catalog_add_aliases('PRI', ARRAY['Puerto Rico']);
SELECT public.international_catalog_add_aliases('ARM', ARRAY['Armenia']);
SELECT public.international_catalog_add_aliases('LUX', ARRAY['Luxembourg']);
SELECT public.international_catalog_add_aliases('AZE', ARRAY['Azerbaijan']);
SELECT public.international_catalog_add_aliases('CAF', ARRAY['Central African Rep.']);
SELECT public.international_catalog_add_aliases('CUB', ARRAY['Cuba']);
SELECT public.international_catalog_add_aliases('EST', ARRAY['Estonia']);
SELECT public.international_catalog_add_aliases('LVA', ARRAY['Latvia']);
SELECT public.international_catalog_add_aliases('MDA', ARRAY['Moldova']);
SELECT public.international_catalog_add_aliases('GRD', ARRAY['Grenada']);
SELECT public.international_catalog_add_aliases('LBR', ARRAY['Liberia']);
SELECT public.international_catalog_add_aliases('NER', ARRAY['Niger']);
SELECT public.international_catalog_add_aliases('AFG', ARRAY['Afghanistan']);
SELECT public.international_catalog_add_aliases('ATG', ARRAY['Antigua and Barbuda']);
SELECT public.international_catalog_add_aliases('BDI', ARRAY['Burundi']);
SELECT public.international_catalog_add_aliases('GUY', ARRAY['Guyana']);
SELECT public.international_catalog_add_aliases('MYA', ARRAY['Myanmar']);
SELECT public.international_catalog_add_aliases('RWA', ARRAY['Rwanda']);
SELECT public.international_catalog_add_aliases('BLR', ARRAY['Belarus']);
SELECT public.international_catalog_add_aliases('CAM', ARRAY['Cambodia']);
SELECT public.international_catalog_add_aliases('TCD', ARRAY['Chad']);
SELECT public.international_catalog_add_aliases('LBY', ARRAY['Libya']);
SELECT public.international_catalog_add_aliases('VCT', ARRAY['St Vincent & Grenadines']);
SELECT public.international_catalog_add_aliases('AND', ARRAY['Andorra']);
SELECT public.international_catalog_add_aliases('BGD', ARRAY['Bangladesh']);
SELECT public.international_catalog_add_aliases('BRB', ARRAY['Barbados']);
SELECT public.international_catalog_add_aliases('BMU', ARRAY['Bermuda']);
SELECT public.international_catalog_add_aliases('BRU', ARRAY['Brunei']);
SELECT public.international_catalog_add_aliases('CYM', ARRAY['Cayman Islands']);
SELECT public.international_catalog_add_aliases('TPE', ARRAY['Chinese Taipei']);

CREATE OR REPLACE FUNCTION public.international_generate_nation_code(p_label text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_base text;
  v_code text;
  v_i integer := 0;
BEGIN
  v_base := left(public.international_normalize_nation_label(p_label), 3);
  IF v_base IS NULL OR length(v_base) < 3 THEN
    v_base := 'XXX';
  END IF;
  v_code := v_base;

  WHILE EXISTS (
    SELECT 1 FROM public.international_nations n WHERE n.code = v_code
  ) LOOP
    v_i := v_i + 1;
    v_code := upper(substring(md5(p_label || ':' || v_i::text) FROM 1 FOR 3));
    v_code := regexp_replace(v_code, '[^A-Z]', 'X', 'g');
    IF length(v_code) < 3 THEN
      v_code := rpad(v_code, 3, 'X');
    END IF;
    EXIT WHEN v_i > 200;
  END LOOP;

  RETURN v_code;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_sync_gpdb_nations()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_code text;
  v_emoji text;
  v_rank integer;
  v_inserted integer := 0;
  v_skipped integer := 0;
  v_catalog_code text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(max(seed_rank), 0) INTO v_rank FROM public.international_nations;

  FOR v_row IN
    SELECT
      p."Nation" AS label,
      count(*)::integer AS players
    FROM public."Players" p
    WHERE btrim(coalesce(p."Nation", '')) <> ''
      AND NOT EXISTS (
        SELECT 1
        FROM public.international_nations n
        WHERE n.active = true
          AND public.international_gpdb_matches_nation(p."Nation", n.code)
      )
    GROUP BY p."Nation"
    ORDER BY players DESC, p."Nation"
  LOOP
    v_catalog_code := public.international_catalog_match_code(v_row.label);

    IF v_catalog_code IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.international_nations n
         WHERE n.code = v_catalog_code AND n.active = true
       ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_code := v_catalog_code;

    IF v_code IS NULL THEN
      v_code := public.international_generate_nation_code(v_row.label);
      v_emoji := '🏳️';
    ELSE
      SELECT c.flag_emoji INTO v_emoji
      FROM public.international_nation_catalog c
      WHERE c.code = v_code;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.international_nations n WHERE n.code = v_code
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_rank := v_rank + 1;
    INSERT INTO public.international_nations (code, name, flag_emoji, seed_rank, active)
    VALUES (v_code, v_row.label, coalesce(v_emoji, '🏳️'), v_rank, true);
    v_inserted := v_inserted + 1;
  END LOOP;

  IF to_regprocedure('public.international_refresh_gpdb_label_map()') IS NOT NULL THEN
    PERFORM public.international_refresh_gpdb_label_map();
  END IF;

  IF to_regprocedure('public.international_refresh_nation_player_pool_cache()') IS NOT NULL THEN
    PERFORM public.international_refresh_nation_player_pool_cache();
  END IF;

  RETURN jsonb_build_object(
    'inserted', v_inserted,
    'skipped_existing_code', v_skipped,
    'active_nations', (SELECT count(*) FROM public.international_nations WHERE active = true)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_catalog_add_aliases(text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_generate_nation_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_sync_gpdb_nations() TO authenticated;

NOTIFY pgrst, 'reload schema';
