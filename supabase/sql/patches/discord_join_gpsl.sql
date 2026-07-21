-- =============================================================================
-- Discord-gated GPSL join: registry fields + waiting-list order by Discord join
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS discord_user_id text,
  ADD COLUMN IF NOT EXISTS discord_joined_at timestamptz,
  ADD COLUMN IF NOT EXISTS fairplay_accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS fairplay_version text;

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_owner_registry_discord_user_id_uidx
  ON public.gpsl_owner_registry (discord_user_id)
  WHERE discord_user_id IS NOT NULL;

COMMENT ON COLUMN public.gpsl_owner_registry.discord_user_id IS
  'Discord snowflake; set by Discord-gated self-serve join.';
COMMENT ON COLUMN public.gpsl_owner_registry.discord_joined_at IS
  'Guild member joined_at from Discord; used for waiting-list order when present.';
COMMENT ON COLUMN public.gpsl_owner_registry.fairplay_accepted_at IS
  'When the owner accepted the GPSL fair-play agreement at join.';

-- Tickets for in-progress Discord OAuth → form → create account
CREATE TABLE IF NOT EXISTS public.discord_join_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_token text NOT NULL UNIQUE,
  discord_user_id text NOT NULL,
  discord_username text,
  suggested_tag text,
  discord_joined_at timestamptz,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS discord_join_tickets_discord_user_idx
  ON public.discord_join_tickets (discord_user_id);

ALTER TABLE public.discord_join_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS discord_join_tickets_no_client ON public.discord_join_tickets;
CREATE POLICY discord_join_tickets_no_client ON public.discord_join_tickets
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

-- Service role bypasses RLS; no grants to authenticated.

-- Waiting list order: Discord join time when known, else auth account created_at
CREATE OR REPLACE FUNCTION public.waiting_list_queue_at(p_owner_id uuid)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT r.discord_joined_at
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = p_owner_id
    ),
    (
      SELECT u.created_at
      FROM auth.users u
      WHERE u.id = p_owner_id
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.waiting_list_ordered_rows(p_include_email boolean DEFAULT false)
RETURNS TABLE (
  owner_id uuid,
  list_position int,
  owner_tag text,
  registry_status text,
  waiting_list_tier text,
  account_created_at timestamptz,
  email text,
  last_club_short_name text,
  absence_note text,
  returned_to_list_at timestamptz,
  pending_starting_balance numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN QUERY
  WITH base AS (
    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      r.waiting_list_tier,
      coalesce(r.discord_joined_at, u.created_at) AS account_created_at,
      CASE WHEN p_include_email THEN u.email::text ELSE NULL END AS email,
      r.last_club_short_name,
      r.absence_note,
      r.returned_to_list_at,
      r.pending_starting_balance
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    WHERE public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
  ),
  ranked AS (
    SELECT
      b.*,
      row_number() OVER (
        ORDER BY
          public.waiting_list_tier_rank(b.waiting_list_tier),
          CASE
            WHEN EXISTS (
              SELECT 1 FROM public.gpsl_owner_registry r2
              WHERE r2.owner_id = b.owner_id
                AND r2.waiting_list_use_admin_sort
                AND r2.waiting_list_admin_sort IS NOT NULL
            ) THEN (
              SELECT r2.waiting_list_admin_sort
              FROM public.gpsl_owner_registry r2
              WHERE r2.owner_id = b.owner_id
            )
          END NULLS LAST,
          b.account_created_at,
          b.owner_id
      )::int AS list_position
    FROM base b
  )
  SELECT
    ranked.owner_id,
    ranked.list_position,
    ranked.owner_tag,
    ranked.registry_status,
    ranked.waiting_list_tier,
    ranked.account_created_at,
    ranked.email,
    ranked.last_club_short_name,
    ranked.absence_note,
    ranked.returned_to_list_at,
    ranked.pending_starting_balance
  FROM ranked
  ORDER BY ranked.list_position;
END;
$function$;

-- Keep rebuild admin sort aligned with Discord join when present
CREATE OR REPLACE FUNCTION public.waiting_list_rebuild_admin_sort()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_sort int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_row IN
    SELECT r.owner_id
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    WHERE public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
    ORDER BY
      public.waiting_list_tier_rank(r.waiting_list_tier),
      CASE WHEN r.waiting_list_use_admin_sort AND r.waiting_list_admin_sort IS NOT NULL
        THEN r.waiting_list_admin_sort END NULLS LAST,
      coalesce(r.discord_joined_at, u.created_at),
      r.owner_id
  LOOP
    v_sort := v_sort + 1000;
    UPDATE public.gpsl_owner_registry
    SET waiting_list_admin_sort = v_sort,
        waiting_list_use_admin_sort = true
    WHERE owner_id = v_row.owner_id;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_queue_at(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
