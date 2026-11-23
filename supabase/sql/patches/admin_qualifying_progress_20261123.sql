-- Admin: where each qualifying owner is, before a film is even in.
-- Same stages as the owner page. Accounts that already have a club are left out.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.admin_qualifying_progress()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin_or_mod()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.stage_sort, x.owner_tag, x.owner_id)
    FROM (
      SELECT
        s.owner_id,
        coalesce(nullif(btrim(public.owner_registry_resolve_tag(s.owner_id)), ''), '—') AS owner_tag,
        s.tag_done,
        s.availability_slots,
        s.friendly_count,
        s.video_status,
        s.upload_code,
        s.handpick_club,
        s.handpick_due_at,
        s.friendly_deadline,
        s.video_deadline,
        s.reset_count,
        CASE
          WHEN s.handpick_club IS NOT NULL THEN 'handpick'
          WHEN s.video_status = 'approved' THEN 'waiting_list'
          WHEN s.video_status = 'submitted' THEN 'with_staff'
          WHEN s.friendly_count >= 5 THEN 'record'
          WHEN s.tag_done AND s.availability_slots > 0 THEN 'friendlies'
          ELSE 'who_you_are'
        END AS stage,
        CASE
          WHEN s.handpick_club IS NOT NULL THEN 6
          WHEN s.video_status = 'approved' THEN 5
          WHEN s.video_status = 'submitted' THEN 4
          WHEN s.friendly_count >= 5 THEN 3
          WHEN s.tag_done AND s.availability_slots > 0 THEN 2
          ELSE 1
        END AS stage_sort
      FROM (
        SELECT
          u.id AS owner_id,
          nullif(btrim(public.owner_registry_resolve_tag(u.id)), '') IS NOT NULL AS tag_done,
          (
            SELECT count(*)::int
            FROM public.gpsl_owner_registry_availability_slot sl
            WHERE sl.owner_id = u.id
          ) AS availability_slots,
          (
            SELECT count(*)::int
            FROM public.gpsl_qualifying_friendly f
            WHERE f.owner_id = u.id
          ) AS friendly_count,
          v.status AS video_status,
          public.owner_qualifying_upload_code(u.id) AS upload_code,
          CASE
            WHEN g.handpick_due_at IS NULL OR g.handpick_due_at >= now()
              THEN nullif(upper(btrim(g.handpick_club)), '')
            ELSE NULL
          END AS handpick_club,
          CASE
            WHEN g.handpick_due_at IS NULL OR g.handpick_due_at >= now()
              THEN g.handpick_due_at
            ELSE NULL
          END AS handpick_due_at,
          public.qualifying_window_started_at(u.id) + interval '7 days' AS friendly_deadline,
          public.qualifying_window_started_at(u.id) + interval '7 days' + interval '72 hours' AS video_deadline,
          coalesce(w.reset_count, 0) AS reset_count
        FROM auth.users u
        JOIN public.gpsl_qualifying_settings qs ON qs.id = 1
        LEFT JOIN LATERAL (
          SELECT v.status
          FROM public.gpsl_qualifying_video v
          WHERE v.owner_id = u.id
          ORDER BY v.created_at DESC
          LIMIT 1
        ) v ON true
        LEFT JOIN public.gpsl_qualifying_grant g ON g.owner_id = u.id
        LEFT JOIN public.gpsl_qualifying_window w ON w.owner_id = u.id
        WHERE u.created_at >= qs.required_from
          AND NOT EXISTS (
            SELECT 1 FROM public."Clubs" c WHERE c.owner_id = u.id
          )
      ) s
    ) x
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_qualifying_progress() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_qualifying_progress() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
