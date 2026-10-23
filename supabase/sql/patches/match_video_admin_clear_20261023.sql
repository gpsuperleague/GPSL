-- =============================================================================
-- Admin: clear a match-video tick (matched and/or pending hold)
-- =============================================================================
-- Use when a test Discord upload / wrong match needs removing from a fixture.
-- Soft-reverses gate_match_video credit if one was posted.
-- Safe re-run.
--
-- Example:
--   SELECT public.match_video_admin_clear(8962, 'home');  -- Jubilo home MD1
--   SELECT public.match_video_admin_clear(8962, NULL);    -- both sides
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_video_admin_clear(
  p_fixture_id bigint,
  p_side text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_side text := nullif(lower(btrim(coalesce(p_side, ''))), '');
  v_vid public.fixture_match_videos%ROWTYPE;
  v_pend_count int := 0;
  v_vid_count int := 0;
  v_ledger_reversed int := 0;
  v_amount numeric;
  v_club text;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role'
     AND session_user NOT IN ('postgres', 'supabase_admin') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF v_side IS NOT NULL AND v_side NOT IN ('home', 'away') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'side must be home, away, or null');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_fixtures f WHERE f.id = p_fixture_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  -- Pending Discord holds (⏳ ticks before result)
  WITH del AS (
    DELETE FROM public.fixture_match_video_pending p
    WHERE p.fixture_id = p_fixture_id
      AND (v_side IS NULL OR p.side = v_side)
    RETURNING p.id, p.side, p.club_short_name, p.filename
  )
  SELECT count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'pending',
           'id', d.id,
           'side', d.side,
           'club', d.club_short_name,
           'filename', d.filename
         )), '[]'::jsonb)
  INTO v_pend_count, v_details
  FROM del d;

  -- Matched videos (+ reverse credit if posted)
  FOR v_vid IN
    SELECT *
    FROM public.fixture_match_videos v
    WHERE v.fixture_id = p_fixture_id
      AND (v_side IS NULL OR v.side = v_side)
  LOOP
    v_amount := coalesce(v_vid.credited_amount, 0);
    v_club := upper(btrim(v_vid.club_short_name));

    IF v_amount > 0 AND v_club IS NOT NULL AND v_club <> '' THEN
      PERFORM public.competition_credit_club_balance(v_club, -v_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount,
        description, metadata
      ) VALUES (
        v_vid.season_id,
        v_vid.fixture_id,
        v_club,
        'gate_match_video',
        -v_amount,
        format('Match video cleared (admin) — reverse credit vs fixture %s', p_fixture_id),
        jsonb_build_object(
          'cleared_fixture_match_video_id', v_vid.id,
          'side', v_vid.side,
          'source', 'admin_clear',
          'reversed_ledger_entry_id', v_vid.ledger_entry_id
        )
      );
      v_ledger_reversed := v_ledger_reversed + 1;
    END IF;

    DELETE FROM public.fixture_match_videos WHERE id = v_vid.id;
    v_vid_count := v_vid_count + 1;
    v_details := v_details || jsonb_build_array(
      jsonb_build_object(
        'kind', 'matched',
        'id', v_vid.id,
        'side', v_vid.side,
        'club', v_vid.club_short_name,
        'filename', v_vid.filename,
        'credited_reversed', v_amount
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'side', v_side,
    'pending_cleared', v_pend_count,
    'matched_cleared', v_vid_count,
    'ledger_reversed', v_ledger_reversed,
    'details', v_details
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_admin_clear(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_admin_clear(bigint, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- One-shot: Jubilo (home) vs Barcelona MD1 — clear admin/test Discord hold
-- SELECT public.match_video_admin_clear(8962, 'home');
