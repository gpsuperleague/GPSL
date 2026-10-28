-- =============================================================================
-- Records Hall: owner tag = owner in charge when the record was achieved
-- (competition_owner_season_ranking), never the current Clubs.owner.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_alltime_records
  ADD COLUMN IF NOT EXISTS owner_tag text;

CREATE OR REPLACE FUNCTION public.gpsl_records_historical_owner(
  p_club_short text,
  p_season_label text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short, '')));
  v_label text := nullif(btrim(coalesce(p_season_label, '')), '');
  v_owner uuid;
  v_tag text;
BEGIN
  IF v_club = '' THEN
    RETURN NULL;
  END IF;

  -- Strip trailing hints like " (≥10 matches)"
  IF v_label IS NOT NULL THEN
    v_label := btrim(regexp_replace(v_label, '\s*\(.*\)$', ''));
  END IF;
  IF v_label IN ('Current', 'League', 'All cups', 'All-time league', 'Cup match', 'Super League') THEN
    v_label := NULL;
  END IF;

  IF to_regclass('public.competition_owner_season_ranking') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT r.owner_id INTO v_owner
  FROM public.competition_owner_season_ranking r
  WHERE upper(r.club_short_name) = v_club
    AND r.owner_id IS NOT NULL
    AND (
      (p_season_id IS NOT NULL AND r.season_id = p_season_id)
      OR (v_label IS NOT NULL AND r.season_label = v_label)
    )
  ORDER BY r.season_id DESC NULLS LAST
  LIMIT 1;

  -- Season label fuzzy: context "Season 2 · …" / "Season 2 (≥10…)"
  IF v_owner IS NULL AND v_label IS NOT NULL THEN
    SELECT r.owner_id INTO v_owner
    FROM public.competition_owner_season_ranking r
    WHERE upper(r.club_short_name) = v_club
      AND r.owner_id IS NOT NULL
      AND (
        r.season_label = v_label
        OR v_label LIKE r.season_label || ' %'
        OR v_label LIKE r.season_label || '·%'
        OR v_label LIKE r.season_label || '· %'
      )
    ORDER BY r.season_id DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_owner IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    IF to_regprocedure('public.owner_registry_resolve_tag(uuid)') IS NOT NULL THEN
      v_tag := nullif(btrim(public.owner_registry_resolve_tag(v_owner)), '');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_tag := NULL;
  END;

  IF v_tag IS NULL AND to_regprocedure('public.competition_owner_display_name(uuid)') IS NOT NULL THEN
    BEGIN
      v_tag := nullif(btrim(public.competition_owner_display_name(v_owner)), '');
    EXCEPTION WHEN OTHERS THEN
      v_tag := NULL;
    END;
  END IF;

  RETURN v_tag;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_records_upsert(
  p_catalog text,
  p_record_id text,
  p_holder_name text,
  p_holder_club text,
  p_holder_key text,
  p_value_num numeric,
  p_value_text text,
  p_context text,
  p_meta jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner text;
  v_club_key text;
  v_season_label text;
  v_season_id bigint;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
BEGIN
  IF p_holder_name IS NULL AND p_value_text IS NULL AND p_value_num IS NULL THEN
    RETURN;
  END IF;

  v_club_key := nullif(btrim(coalesce(p_holder_club, '')), '');
  IF v_club_key IS NULL THEN
    v_club_key := nullif(btrim(coalesce(p_holder_key, '')), '');
  END IF;

  v_season_label := nullif(btrim(coalesce(v_meta->>'season_label', '')), '');
  IF v_season_label IS NULL THEN
    v_season_label := nullif(btrim(coalesce(p_context, '')), '');
  END IF;
  BEGIN
    v_season_id := nullif(v_meta->>'season_id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN
    v_season_id := NULL;
  END;

  IF v_club_key IS NOT NULL THEN
    v_owner := public.gpsl_records_historical_owner(v_club_key, v_season_label, v_season_id);
  END IF;

  INSERT INTO public.gpsl_alltime_records (
    catalog, record_id, holder_name, holder_club, holder_key, owner_tag,
    value_num, value_text, context_label, meta, computed_at
  ) VALUES (
    p_catalog, p_record_id, p_holder_name, p_holder_club, p_holder_key, v_owner,
    p_value_num, p_value_text, p_context, v_meta, now()
  )
  ON CONFLICT (catalog, record_id) DO UPDATE SET
    holder_name = excluded.holder_name,
    holder_club = excluded.holder_club,
    holder_key = excluded.holder_key,
    owner_tag = excluded.owner_tag,
    value_num = excluded.value_num,
    value_text = excluded.value_text,
    context_label = excluded.context_label,
    meta = excluded.meta,
    computed_at = now();
END;
$function$;

-- Prefer historical helper; keep name for older callers but do NOT use current Clubs.owner
CREATE OR REPLACE FUNCTION public.gpsl_records_owner_tag(p_club_short text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpsl_records_historical_owner(p_club_short, NULL, NULL);
$$;

-- Re-apply owner tags on existing rows from season context / meta
UPDATE public.gpsl_alltime_records r
SET owner_tag = public.gpsl_records_historical_owner(
  coalesce(nullif(btrim(r.holder_club), ''), nullif(btrim(r.holder_key), '')),
  coalesce(nullif(btrim(r.meta->>'season_label'), ''), nullif(btrim(r.context_label), '')),
  CASE
    WHEN nullif(btrim(r.meta->>'season_id'), '') ~ '^[0-9]+$'
      THEN (r.meta->>'season_id')::bigint
    ELSE NULL
  END
);

-- Refresh so new upserts store historical owners (and meta season where set)
SELECT public.gpsl_records_refresh() AS refreshed;

NOTIFY pgrst, 'reload schema';
