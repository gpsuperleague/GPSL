-- Season owner board: Discord people with no GPSL account.
-- Safe to re-run.

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
          s.seen_at
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

REVOKE ALL ON FUNCTION public.admin_owner_board_discord_visitors() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_board_discord_visitors() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT to_regprocedure('public.admin_owner_board_discord_visitors()') IS NOT NULL AS ready;
