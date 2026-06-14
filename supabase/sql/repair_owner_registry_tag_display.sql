-- Fix: awaiting_club.html empty tag when tag lives in ranking history (post test reset)
-- Run once in Supabase SQL Editor, then hard-refresh awaiting_club.html

CREATE OR REPLACE FUNCTION public.owner_registry_resolve_tag(p_owner_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT nullif(btrim(r.owner_tag), '')
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = p_owner_id
    ),
    (
      SELECT nullif(btrim(x.owner_tag), '')
      FROM public.competition_owner_season_ranking x
      WHERE x.owner_id = p_owner_id
      ORDER BY x.season_id DESC
      LIMIT 1
    ),
    (
      SELECT nullif(btrim(c.owner), '')
      FROM public."Clubs" c
      WHERE c.owner_id = p_owner_id
      LIMIT 1
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.owner_registry_get_self()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_owner_registry%rowtype;
  v_has_club boolean;
  v_tag text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = auth.uid();

  v_tag := public.owner_registry_resolve_tag(auth.uid());

  RETURN jsonb_build_object(
    'authenticated', true,
    'has_club', v_has_club,
    'status', v_row.status,
    'owner_tag', v_tag,
    'pending_starting_balance', coalesce(v_row.pending_starting_balance, 0),
    'needs_club_auction',
      NOT v_has_club
      AND coalesce(v_row.status, 'awaiting_club_auction') = 'awaiting_club_auction'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_resolve_tag(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;

NOTIFY pgrst, 'reload schema';
