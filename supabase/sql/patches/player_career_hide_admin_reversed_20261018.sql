-- =============================================================================
-- Player career bio: hide admin-reversed Transfer_History rows
--
-- After Besiktas Kane/Arda repair, Arda's overflow sale to Sporting Gijón stayed
-- on the career transfers list because transfer_sale_note = 'admin_reversed'
-- was still returned by competition_player_career_bundle.
--
-- Also clears any leftover foreign_contract lock on Arda from that overflow.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_player_career_bundle(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_player jsonb;
  v_stints jsonb;
  v_honours jsonb;
  v_awards jsonb;
  v_totals jsonb;
  v_transfers jsonb;
  v_discipline jsonb;
BEGIN
  SELECT to_jsonb(p)
  INTO v_player
  FROM (
    SELECT
      p."Konami_ID" AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Rating" AS rating,
      p."Nation" AS nation,
      p."Contracted_Team" AS current_club,
      p."Height" AS height_cm,
      p."Stronger_Foot" AS stronger_foot,
      p."Weak_Foot_Usage" AS weak_foot_usage,
      p."Weak_Foot_Accuracy" AS weak_foot_accuracy
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
    LIMIT 1
  ) p;

  SELECT coalesce(jsonb_agg(row_to_json(c) ORDER BY c.season_label DESC), '[]'::jsonb)
  INTO v_stints
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(h) ORDER BY h.honoured_at DESC), '[]'::jsonb)
  INTO v_honours
  FROM public.competition_player_honours_public h
  WHERE h.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(a) ORDER BY a.season_label DESC), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  WHERE a.player_id = v_pid;

  SELECT jsonb_build_object(
    'appearances', coalesce(sum(appearances), 0),
    'goals', coalesce(sum(goals), 0),
    'assists', coalesce(sum(assists), 0),
    'potm_awards', coalesce(sum(potm_awards), 0),
    'clean_sheets', coalesce(sum(clean_sheets), 0),
    'avg_rating', round(avg(avg_rating) FILTER (WHERE avg_rating IS NOT NULL), 2)
  )
  INTO v_totals
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.transfer_time DESC), '[]'::jsonb)
  INTO v_transfers
  FROM (
    SELECT
      h.player_id::text AS player_id,
      public.transfer_history_season_label(h.transfer_time) AS season_label,
      h.transfer_time,
      h.seller_club_id AS seller_club_short_name,
      h.buyer_club_id AS buyer_club_short_name,
      h.foreign_buyer_name,
      h.transfer_sale_note,
      coalesce(h.fee, 0)::numeric AS fee,
      coalesce(h.agent_fee, 0)::numeric AS agent_fee,
      (coalesce(h.fee, 0) + coalesce(h.agent_fee, 0))::numeric AS total_cost,
      CASE
        WHEN coalesce(h.fee, 0) <= 0 THEN 'free'
        WHEN h.transfer_sale_note = 'squad_overflow' THEN 'overflow_release'
        WHEN h.foreign_buyer_name IS NOT NULL AND btrim(h.foreign_buyer_name) <> '' THEN 'foreign_sale'
        ELSE 'transfer'
      END AS move_kind
    FROM public."Transfer_History" h
    WHERE h.player_id::text = v_pid
      AND coalesce(h.transfer_sale_note, '') IS DISTINCT FROM 'admin_reversed'
      AND coalesce(h.transfer_sale_note, '') NOT LIKE 'admin_reversed%'
  ) t;

  SELECT coalesce(jsonb_agg(row_to_json(d) ORDER BY d.created_at DESC), '[]'::jsonb)
  INTO v_discipline
  FROM (
    SELECT
      s.id AS suspension_id,
      s.season_id,
      se.label AS season_label,
      s.club_short_name,
      s.reason,
      s.yellow_count_at_issue,
      s.ban_matches,
      s.status,
      s.source_fixture_id,
      s.created_at,
      CASE
        WHEN s.reason = 'red_card' THEN 'Red card — 2 match ban'
        WHEN s.reason = 'yellow_accumulation' THEN
          format('Yellow card accumulation (%s) — 2 match ban', coalesce(s.yellow_count_at_issue, 8))
        ELSE s.reason
      END AS summary,
      coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'fixture_id', sm.fixture_id,
            'sequence_no', sm.sequence_no,
            'served', sm.served,
            'label', public.competition_fixture_discipline_label(f, s.club_short_name)
          )
          ORDER BY sm.sequence_no
        )
        FROM public.competition_player_suspension_matches sm
        JOIN public.competition_fixtures f ON f.id = sm.fixture_id
        WHERE sm.suspension_id = s.id
      ), '[]'::jsonb) AS matches
    FROM public.competition_player_suspensions s
    LEFT JOIN public.competition_seasons se ON se.id = s.season_id
    WHERE s.player_id = v_pid
  ) d;

  RETURN jsonb_build_object(
    'player', coalesce(v_player, '{}'::jsonb),
    'stints', coalesce(v_stints, '[]'::jsonb),
    'honours', coalesce(v_honours, '[]'::jsonb),
    'awards', coalesce(v_awards, '[]'::jsonb),
    'totals', coalesce(v_totals, '{}'::jsonb),
    'transfers', coalesce(v_transfers, '[]'::jsonb),
    'discipline', coalesce(v_discipline, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_player_career_bundle(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Arda: ensure overflow row is marked reversed + clear foreign no-buy leftovers
-- ---------------------------------------------------------------------------
DO $arda$
DECLARE
  v_arda text;
  v_n int;
BEGIN
  SELECT p."Konami_ID"::text INTO v_arda
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Arda%G_l_r%'
     OR p."Name" ILIKE '%Arda Guler%'
     OR p."Name" ILIKE '%Arda Güler%'
  ORDER BY CASE
    WHEN upper(btrim(coalesce(p."Contracted_Team", ''))) = 'BES' THEN 0
    WHEN p."Contracted_Team" IS NULL THEN 1
    ELSE 2
  END, p."Konami_ID"
  LIMIT 1;

  IF v_arda IS NULL THEN
    RAISE NOTICE 'Arda Güler not found — career filter still applied globally';
    RETURN;
  END IF;

  UPDATE public."Transfer_History" h
  SET transfer_sale_note = 'admin_reversed',
      foreign_buyer_name = CASE
        WHEN coalesce(h.foreign_buyer_name, '') LIKE '%[reversed%' THEN h.foreign_buyer_name
        ELSE coalesce(h.foreign_buyer_name, '') || ' [reversed 20261018]'
      END
  WHERE h.player_id::text = v_arda
    AND upper(btrim(h.seller_club_id::text)) = 'BES'
    AND upper(btrim(coalesce(h.buyer_club_id::text, ''))) IN ('FOREIGN', 'FA', '')
    AND h.transfer_time > now() - interval '14 days'
    AND (
      coalesce(h.transfer_sale_note, '') = 'squad_overflow'
      OR coalesce(h.transfer_sale_note, '') = 'special_auction_keep_prep'
      OR coalesce(h.foreign_buyer_name, '') ILIKE '%Sporting Gij_n%'
      OR coalesce(h.foreign_buyer_name, '') ILIKE '%Gijon%'
    )
    AND coalesce(h.transfer_sale_note, '') IS DISTINCT FROM 'admin_reversed';

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'Arda history rows marked admin_reversed: %', v_n;

  -- Overflow foreign sale can leave a season lock; clear if still pointing abroad
  UPDATE public."Players" p
  SET foreign_contract_club = NULL,
      foreign_contract_sold_season_id = NULL,
      foreign_contract_unlock_season_label = NULL,
      foreign_contract_lock_kind = NULL
  WHERE p."Konami_ID"::text = v_arda
    AND (
      coalesce(p.foreign_contract_lock_kind, '') IN ('foreign', 'paid_up')
      OR coalesce(p.foreign_contract_club, '') ILIKE '%Gij%'
      OR coalesce(p.foreign_contract_club, '') ILIKE '%Sporting%'
    );
END
$arda$;

NOTIFY pgrst, 'reload schema';
