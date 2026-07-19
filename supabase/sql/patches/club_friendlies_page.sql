-- =============================================================================
-- My Club → Friendlies page RPC
-- Standalone Discord friendlies only — no league/cup/player history hooks.
-- Run after discord_friendlies_gate.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_friendlies_my_club()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season_id bigint;
  v_active_month text;
  v_season_paid numeric := 0;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'No club linked to this login',
      'club', NULL,
      'months', '[]'::jsonb
    );
  END IF;

  v_season_id := public.gpsl_friendlies_live_season_id();
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NOT NULL THEN
    v_active_month := public.competition_active_gpsl_month(v_season_id, now());
    v_season_paid := public.gpsl_friendlies_season_paid_total(v_season_id, v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'season_id', v_season_id,
    'active_gpsl_month', v_active_month,
    'active_gpsl_month_label', CASE
      WHEN v_active_month IS NULL THEN NULL
      ELSE public.competition_gpsl_month_label(v_active_month)
    END,
    'payout_amount', public.gpsl_friendlies_payout_amount(),
    'month_cap', public.gpsl_friendlies_month_cap(),
    'season_cap', public.gpsl_friendlies_season_cap(),
    'season_paid_total', v_season_paid,
    'months', coalesce((
      SELECT jsonb_agg(m.month_obj ORDER BY m.sort_order)
      FROM (
        SELECT
          x.gpsl_month,
          public.competition_gpsl_month_sort(x.gpsl_month) AS sort_order,
          jsonb_build_object(
            'gpsl_month', x.gpsl_month,
            'gpsl_month_label', public.competition_gpsl_month_label(x.gpsl_month),
            'paid_count', (
              SELECT count(*)::int
              FROM public.gpsl_friendlies f2
              WHERE f2.season_id = v_season_id
                AND f2.gpsl_month = x.gpsl_month
                AND (
                  (upper(f2.club_left) = v_club AND f2.paid_left > 0)
                  OR (upper(f2.club_right) = v_club AND f2.paid_right > 0)
                )
            ),
            'month_cap', public.gpsl_friendlies_month_cap(),
            'friendlies', coalesce((
              SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.confirmed_at DESC)
              FROM (
                SELECT
                  f.id,
                  'confirmed'::text AS status,
                  f.gpsl_month,
                  f.club_left,
                  lc."Club" AS club_left_name,
                  f.score_left,
                  f.club_right,
                  rc."Club" AS club_right_name,
                  f.score_right,
                  coalesce(nullif(btrim(lc."Stadium"), ''), lc."Club", f.club_left) AS stadium,
                  f.confirmed_at,
                  (upper(f.club_left) = v_club) AS is_home,
                  CASE
                    WHEN upper(f.club_left) = v_club THEN f.paid_left
                    ELSE f.paid_right
                  END AS my_payout,
                  CASE
                    WHEN upper(f.club_left) = v_club THEN f.left_skipped_reason
                    ELSE f.right_skipped_reason
                  END AS my_payout_skipped
                FROM public.gpsl_friendlies f
                LEFT JOIN public."Clubs" lc ON upper(lc."ShortName") = upper(f.club_left)
                LEFT JOIN public."Clubs" rc ON upper(rc."ShortName") = upper(f.club_right)
                WHERE f.season_id = v_season_id
                  AND f.gpsl_month = x.gpsl_month
                  AND (
                    upper(f.club_left) = v_club
                    OR upper(f.club_right) = v_club
                  )
              ) t
            ), '[]'::jsonb),
            'pending', coalesce((
              SELECT jsonb_agg(row_to_json(p)::jsonb ORDER BY p.posted_at DESC)
              FROM (
                SELECT
                  r.id,
                  'pending'::text AS status,
                  r.gpsl_month,
                  r.reporter_club_short_name,
                  r.club_left,
                  lc."Club" AS club_left_name,
                  r.score_left,
                  r.club_right,
                  rc."Club" AS club_right_name,
                  r.score_right,
                  coalesce(nullif(btrim(lc."Stadium"), ''), lc."Club", r.club_left) AS stadium,
                  r.posted_at,
                  (upper(r.club_left) = v_club) AS is_home,
                  (upper(r.reporter_club_short_name) = v_club) AS i_reported
                FROM public.gpsl_friendly_reports r
                LEFT JOIN public."Clubs" lc ON upper(lc."ShortName") = upper(r.club_left)
                LEFT JOIN public."Clubs" rc ON upper(rc."ShortName") = upper(r.club_right)
                WHERE r.season_id = v_season_id
                  AND r.gpsl_month = x.gpsl_month
                  AND r.status = 'pending'
                  AND (
                    upper(r.club_left) = v_club
                    OR upper(r.club_right) = v_club
                  )
              ) p
            ), '[]'::jsonb)
          ) AS month_obj
        FROM (
          SELECT DISTINCT gpsl_month
          FROM public.gpsl_friendlies
          WHERE season_id = v_season_id
            AND (upper(club_left) = v_club OR upper(club_right) = v_club)
          UNION
          SELECT DISTINCT gpsl_month
          FROM public.gpsl_friendly_reports
          WHERE season_id = v_season_id
            AND status = 'pending'
            AND (upper(club_left) = v_club OR upper(club_right) = v_club)
        ) x
      ) m
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_friendlies_my_club() TO authenticated;

COMMENT ON FUNCTION public.club_friendlies_my_club() IS
  'My Club Friendlies: Discord-confirmed friendlies + pending for logged-in club. No league/cup/player links.';
