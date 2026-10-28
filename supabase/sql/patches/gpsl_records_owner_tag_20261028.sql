-- =============================================================================
-- All-time records: store / resolve owner tag under the club
-- Safe re-run. Re-refresh after apply.
-- =============================================================================

ALTER TABLE public.gpsl_alltime_records
  ADD COLUMN IF NOT EXISTS owner_tag text;

CREATE OR REPLACE FUNCTION public.gpsl_records_owner_tag(p_club_short text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT nullif(btrim(c.owner::text), '')
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;
$$;

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
BEGIN
  IF p_holder_name IS NULL AND p_value_text IS NULL AND p_value_num IS NULL THEN
    RETURN;
  END IF;

  -- Prefer explicit club short; else holder_key when it is a club
  v_club_key := nullif(btrim(coalesce(p_holder_club, '')), '');
  IF v_club_key IS NULL THEN
    v_club_key := nullif(btrim(coalesce(p_holder_key, '')), '');
  END IF;
  IF v_club_key IS NOT NULL THEN
    v_owner := public.gpsl_records_owner_tag(v_club_key);
  END IF;

  INSERT INTO public.gpsl_alltime_records (
    catalog, record_id, holder_name, holder_club, holder_key, owner_tag,
    value_num, value_text, context_label, meta, computed_at
  ) VALUES (
    p_catalog, p_record_id, p_holder_name, p_holder_club, p_holder_key, v_owner,
    p_value_num, p_value_text, p_context, coalesce(p_meta, '{}'::jsonb), now()
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

GRANT EXECUTE ON FUNCTION public.gpsl_records_owner_tag(text) TO authenticated, anon;

-- Backfill owner tags on existing rows, then refresh
UPDATE public.gpsl_alltime_records r
SET owner_tag = public.gpsl_records_owner_tag(coalesce(nullif(btrim(r.holder_club), ''), r.holder_key))
WHERE r.owner_tag IS NULL
  AND coalesce(nullif(btrim(r.holder_club), ''), r.holder_key) IS NOT NULL;

SELECT public.gpsl_records_refresh() AS refreshed;

NOTIFY pgrst, 'reload schema';
