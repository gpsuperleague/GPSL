-- =============================================================================
-- Discord visitor accounts — read-only spectators
--
-- The discord-visitor-login edge function signs GPSL Discord server members in
-- as visitors: one auth user per Discord account, recorded here, with
-- app_metadata.gpsl_visitor = true. Visitors have no club and no owner
-- registry row, so owner lists, the waiting list and bidding all ignore them.
-- The triggers below stop a visitor calling owner self-service RPCs directly
-- to create registry / availability / interest rows.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_visitors (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  discord_user_id text NOT NULL UNIQUE,
  discord_username text,
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz NOT NULL DEFAULT now(),
  login_count int NOT NULL DEFAULT 1,
  is_blocked boolean NOT NULL DEFAULT false
);

ALTER TABLE public.gpsl_visitors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_visitors_admin ON public.gpsl_visitors;
CREATE POLICY gpsl_visitors_admin ON public.gpsl_visitors
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS gpsl_visitors_self_read ON public.gpsl_visitors;
CREATE POLICY gpsl_visitors_self_read ON public.gpsl_visitors
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.gpsl_user_is_visitor(p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_uid IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.gpsl_visitors v WHERE v.user_id = p_uid);
$$;

CREATE OR REPLACE FUNCTION public.is_gpsl_visitor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpsl_user_is_visitor(auth.uid());
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_user_is_visitor(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_gpsl_visitor() TO authenticated;

-- ---------------------------------------------------------------------------
-- Block visitor-owned rows on owner self-service tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_block_gpsl_visitor_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF public.gpsl_user_is_visitor(NEW.owner_id) THEN
    RAISE EXCEPTION 'Visitor accounts are read-only';
  END IF;
  RETURN NEW;
END;
$function$;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'gpsl_owner_registry',
    'gpsl_owner_registry_availability_slot',
    'club_auction_interests',
    'natter_reactions'
  ]
  LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS block_gpsl_visitor ON public.%I', t);
      EXECUTE format(
        'CREATE TRIGGER block_gpsl_visitor BEFORE INSERT OR UPDATE ON public.%I '
        'FOR EACH ROW EXECUTE FUNCTION public.trg_block_gpsl_visitor_owner()',
        t
      );
    END IF;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin: list / block visitors
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpsl_visitors_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(v) ORDER BY v.last_login_at DESC)
    FROM public.gpsl_visitors v
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpsl_visitor_set_blocked(
  p_user_id uuid,
  p_blocked boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  UPDATE public.gpsl_visitors
  SET is_blocked = coalesce(p_blocked, false)
  WHERE user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Visitor not found';
  END IF;
  RETURN jsonb_build_object('ok', true, 'user_id', p_user_id, 'is_blocked', coalesce(p_blocked, false));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpsl_visitors_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpsl_visitor_set_blocked(uuid, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
