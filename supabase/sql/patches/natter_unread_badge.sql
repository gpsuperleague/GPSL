-- =============================================================================
-- Natter unread badge — posts from other owners since last visit
-- Run after natter_platform.sql
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.natter_reads (
  owner_id uuid PRIMARY KEY,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.natter_reads IS
  'Per-owner last Natter visit — drives nav unread badge.';

ALTER TABLE public.natter_reads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS natter_reads_select ON public.natter_reads;
CREATE POLICY natter_reads_select ON public.natter_reads
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS natter_reads_insert ON public.natter_reads;
CREATE POLICY natter_reads_insert ON public.natter_reads
  FOR INSERT TO authenticated
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS natter_reads_update ON public.natter_reads;
CREATE POLICY natter_reads_update ON public.natter_reads
  FOR UPDATE TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

CREATE OR REPLACE FUNCTION public.natter_unread_count()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_season_id bigint;
  v_last_seen timestamptz;
  v_count int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'count', 0);
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'count', 0, 'season_id', NULL);
  END IF;

  SELECT r.last_seen_at INTO v_last_seen
  FROM public.natter_reads r
  WHERE r.owner_id = v_uid;

  SELECT count(*)::int INTO v_count
  FROM public.natter_posts p
  WHERE p.season_id = v_season_id
    AND p.owner_id IS DISTINCT FROM v_uid
    AND (v_last_seen IS NULL OR p.created_at > v_last_seen);

  RETURN jsonb_build_object(
    'ok', true,
    'count', coalesce(v_count, 0),
    'season_id', v_season_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.natter_mark_seen()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  INSERT INTO public.natter_reads (owner_id, last_seen_at, updated_at)
  VALUES (v_uid, now(), now())
  ON CONFLICT (owner_id) DO UPDATE
  SET last_seen_at = excluded.last_seen_at,
      updated_at = excluded.updated_at;

  RETURN jsonb_build_object('ok', true, 'count', 0);
END;
$function$;

GRANT SELECT, INSERT, UPDATE ON public.natter_reads TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_unread_count() TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_mark_seen() TO authenticated;

NOTIFY pgrst, 'reload schema';
