-- =============================================================================
-- GPFL: public prize board (pot amounts + paid winners)
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpfl_prizes_board(
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_cfg public.gpfl_settings%rowtype;
  v_payouts jsonb := '[]'::jsonb;
BEGIN
  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_gs_id IS NOT NULL THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'scope', r.scope,
          'gpsl_month', r.gpsl_month,
          'place', r.place,
          'amount', r.amount,
          'paid_at', r.paid_at,
          'team_name', r.team_name,
          'owner_name', r.owner_name,
          'owner_tag', r.owner_tag,
          'is_me', r.is_me
        )
        ORDER BY r.sort_scope, r.sort_month, r.place
      ),
      '[]'::jsonb
    )
    INTO v_payouts
    FROM (
      SELECT
        p.scope,
        p.gpsl_month,
        p.place,
        p.amount,
        p.created_at AS paid_at,
        e.team_name,
        public.competition_owner_display_name(p.owner_id) AS owner_name,
        public.owner_registry_resolve_tag(p.owner_id) AS owner_tag,
        p.owner_id = auth.uid() AS is_me,
        CASE WHEN p.scope = 'season' THEN 0 ELSE 1 END AS sort_scope,
        CASE lower(coalesce(p.gpsl_month, ''))
          WHEN 'august' THEN 1
          WHEN 'september' THEN 2
          WHEN 'october' THEN 3
          WHEN 'november' THEN 4
          WHEN 'december' THEN 5
          WHEN 'january' THEN 6
          WHEN 'february' THEN 7
          WHEN 'march' THEN 8
          WHEN 'april' THEN 9
          WHEN 'may' THEN 10
          ELSE 99
        END AS sort_month
      FROM public.gpfl_prize_payouts p
      LEFT JOIN public.gpfl_entries e ON e.id = p.entry_id
      WHERE p.gpfl_season_id = v_gs_id
    ) r;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'enabled', coalesce(v_cfg.cash_prizes_enabled, false),
    'season', jsonb_build_array(
      jsonb_build_object('place', 1, 'amount', coalesce(v_cfg.prize_season_1, 0)),
      jsonb_build_object('place', 2, 'amount', coalesce(v_cfg.prize_season_2, 0)),
      jsonb_build_object('place', 3, 'amount', coalesce(v_cfg.prize_season_3, 0))
    ),
    'month', jsonb_build_array(
      jsonb_build_object('place', 1, 'amount', coalesce(v_cfg.prize_month_1, 0)),
      jsonb_build_object('place', 2, 'amount', coalesce(v_cfg.prize_month_2, 0)),
      jsonb_build_object('place', 3, 'amount', coalesce(v_cfg.prize_month_3, 0))
    ),
    'payouts', coalesce(v_payouts, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_prizes_board(bigint) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
