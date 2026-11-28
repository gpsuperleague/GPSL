-- Season 2 check for Discord people who have no GPSL account.
-- Stored on the presence snapshot, keyed by Discord user id.
-- A presence upsert only writes name, role, and seen times, so these columns stay.
-- Safe to re-run.

ALTER TABLE public.gpsl_discord_guild_seen
  ADD COLUMN IF NOT EXISTS season2_check_status text,
  ADD COLUMN IF NOT EXISTS season2_check_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS season2_check_deadline_at timestamptz;

ALTER TABLE public.gpsl_discord_guild_seen
  DROP CONSTRAINT IF EXISTS gpsl_discord_guild_seen_season2_check_status_check;

ALTER TABLE public.gpsl_discord_guild_seen
  ADD CONSTRAINT gpsl_discord_guild_seen_season2_check_status_check
  CHECK (
    season2_check_status IS NULL
    OR season2_check_status IN ('sent', 'season2', 'later', 'discord', 'away', 'no_reply')
  );

CREATE OR REPLACE FUNCTION public.admin_discord_visitor_set_season2_check(
  p_discord_user_id text,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id text := nullif(btrim(coalesce(p_discord_user_id, '')), '');
  v_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
  v_sent timestamptz;
  v_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Choose a Discord visitor';
  END IF;
  IF v_status IS NOT NULL AND v_status NOT IN ('sent', 'season2', 'later', 'discord', 'away', 'no_reply') THEN
    RAISE EXCEPTION 'Unknown Season 2 check';
  END IF;

  IF v_status IS NULL THEN
    UPDATE public.gpsl_discord_guild_seen s
    SET season2_check_status = NULL,
        season2_check_sent_at = NULL,
        season2_check_deadline_at = NULL
    WHERE s.discord_user_id = v_id;
  ELSIF v_status = 'sent' THEN
    v_sent := now();
    v_deadline := v_sent + interval '7 days';
    UPDATE public.gpsl_discord_guild_seen s
    SET season2_check_status = 'sent',
        season2_check_sent_at = v_sent,
        season2_check_deadline_at = v_deadline
    WHERE s.discord_user_id = v_id;
  ELSE
    UPDATE public.gpsl_discord_guild_seen s
    SET season2_check_status = v_status
    WHERE s.discord_user_id = v_id
    RETURNING s.season2_check_sent_at, s.season2_check_deadline_at
    INTO v_sent, v_deadline;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'That person is not in the Discord snapshot';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'discord_user_id', v_id,
    'status', v_status,
    'sent_at', v_sent,
    'deadline_at', v_deadline
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_owner_board_discord_visitors()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(to_jsonb(q) ORDER BY q.joined_at DESC NULLS LAST, q.display_name)
      FROM (
        SELECT
          s.discord_user_id,
          s.display_name,
          s.tier,
          s.joined_at,
          s.seen_at,
          s.season2_check_status,
          s.season2_check_sent_at,
          s.season2_check_deadline_at
        FROM public.gpsl_discord_guild_seen s
        WHERE NOT EXISTS (
          SELECT 1
          FROM public.gpsl_owner_registry r
          WHERE nullif(btrim(r.discord_user_id), '') = s.discord_user_id
             OR (
               nullif(btrim(s.display_name), '') IS NOT NULL
               AND lower(btrim(r.owner_tag)) = lower(btrim(s.display_name))
             )
        )
      ) q
    ),
    '[]'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_discord_visitor_set_season2_check(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_owner_board_discord_visitors() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_discord_visitor_set_season2_check(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_board_discord_visitors() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'status_column', EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpsl_discord_guild_seen'
      AND column_name = 'season2_check_status'
  ),
  'setter', to_regprocedure('public.admin_discord_visitor_set_season2_check(text,text)') IS NOT NULL,
  'list', to_regprocedure('public.admin_owner_board_discord_visitors()') IS NOT NULL
) AS ready;
