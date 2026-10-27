-- =============================================================================
-- Fix: Owners Shop medical tokens not appearing in Medical Room / Squad
--
-- Cause: owners_shop_agent_bribe_aisle_20261020.sql replaced
-- prize_grant_inventory_item() and dropped medical_create_named_consult().
-- UI lists club_medical_consults only — inventory rows alone are invisible.
--
-- This patch:
--   1) Restores named-consult creation on medical_token grants (keeps agent_bribe)
--   2) Backfills orphan available medical_token inventory → consult rows
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.prize_grant_inventory_item(
  p_club text,
  p_prize_type text,
  p_param_int int,
  p_source text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_window_phase text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := btrim(p_club);
  v_meta jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_ident jsonb;
  v_consult_id bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF p_prize_type NOT IN (
    'medical_token', 'fee_discount', 'appeal_card', 'draft_token',
    'ban_reduction', 'agent_bribe'
  ) THEN
    RAISE EXCEPTION 'Invalid prize type %', p_prize_type;
  END IF;

  IF p_prize_type = 'medical_token'
     AND to_regprocedure('public.medical_random_consultancy_identity()') IS NOT NULL THEN
    v_ident := public.medical_random_consultancy_identity();
    v_meta := v_meta || jsonb_build_object(
      'matches_removed', p_param_int,
      'group_name', v_ident->>'group_name',
      'consultant_name', v_ident->>'consultant_name',
      'label', v_ident->>'label',
      'consultancy_label', v_ident->>'label'
    );
  END IF;

  IF p_prize_type = 'agent_bribe' THEN
    v_meta := v_meta || jsonb_build_object(
      'label', 'Brown envelope — agent introduction',
      'underhanded', true
    );
  END IF;

  INSERT INTO public.club_prize_inventory (
    club_short_name, prize_type, param_int, source, season_id, window_phase, metadata
  )
  VALUES (
    v_club,
    p_prize_type,
    CASE
      WHEN p_prize_type IN ('appeal_card', 'draft_token', 'ban_reduction', 'agent_bribe')
        THEN NULL
      ELSE p_param_int
    END,
    p_source,
    p_season_id,
    p_window_phase,
    v_meta
  )
  RETURNING id INTO v_id;

  -- Link Medical Room / Squad dropdown (named consult row)
  IF p_prize_type = 'medical_token'
     AND to_regprocedure(
       'public.medical_create_named_consult(text,int,text,bigint,jsonb)'
     ) IS NOT NULL THEN
    v_consult_id := public.medical_create_named_consult(
      v_club,
      p_param_int,
      coalesce(p_source, 'prize'),
      v_id,
      v_ident
    );
    UPDATE public.club_prize_inventory
    SET metadata = coalesce(metadata, '{}'::jsonb)
      || jsonb_build_object('consult_id', v_consult_id)
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Backfill: available medical_token inventory with no consult row
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  r record;
  v_ident jsonb;
  v_cid bigint;
  n int := 0;
BEGIN
  IF to_regclass('public.club_medical_consults') IS NULL THEN
    RAISE NOTICE 'club_medical_consults missing — backfill skipped';
    RETURN;
  END IF;
  IF to_regprocedure(
    'public.medical_create_named_consult(text,int,text,bigint,jsonb)'
  ) IS NULL THEN
    RAISE NOTICE 'medical_create_named_consult missing — backfill skipped';
    RETURN;
  END IF;

  FOR r IN
    SELECT i.id, i.club_short_name, i.param_int, i.source, i.metadata
    FROM public.club_prize_inventory i
    WHERE i.prize_type = 'medical_token'
      AND i.status = 'available'
      AND NOT EXISTS (
        SELECT 1
        FROM public.club_medical_consults c
        WHERE c.inventory_id = i.id
      )
  LOOP
    IF coalesce(nullif(r.metadata->>'label', ''), '') <> '' THEN
      v_ident := jsonb_build_object(
        'group_name', coalesce(r.metadata->>'group_name', 'Harley Medical Group'),
        'consultant_name', coalesce(r.metadata->>'consultant_name', 'Helen Roberts'),
        'label', r.metadata->>'label'
      );
    ELSIF to_regprocedure('public.medical_random_consultancy_identity()') IS NOT NULL THEN
      v_ident := public.medical_random_consultancy_identity();
    ELSE
      v_ident := NULL;
    END IF;

    v_cid := public.medical_create_named_consult(
      r.club_short_name,
      coalesce(r.param_int, 2),
      coalesce(r.source, 'prize_backfill'),
      r.id,
      v_ident
    );

    UPDATE public.club_prize_inventory
    SET metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'consult_id', v_cid,
      'group_name', coalesce(v_ident->>'group_name', metadata->>'group_name'),
      'consultant_name', coalesce(v_ident->>'consultant_name', metadata->>'consultant_name'),
      'label', coalesce(v_ident->>'label', metadata->>'label'),
      'consultancy_label', coalesce(v_ident->>'label', metadata->>'consultancy_label'),
      'matches_removed', coalesce(r.param_int, 2)
    )
    WHERE id = r.id;

    n := n + 1;
  END LOOP;

  RAISE NOTICE 'Backfilled % orphan medical_token inventory row(s) → consults', n;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';
