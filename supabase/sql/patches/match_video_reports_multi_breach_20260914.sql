-- =============================================================================
-- Match video reports: multi-breach + one report per match side + approve/reject
-- (2026-09-14)
--
-- • One report per fixture side (ever). Rejected/approved both lock re-reporting.
-- • Report carries jsonb breaches: [{code, note}, ...] — every note required.
-- • Admin/mod Approve → ₿2,000 Building Society to reporter (+ fines per breach).
-- • Admin/mod Reject → closed; no further reports on that side.
-- Safe re-run.
-- =============================================================================

-- Allow new statuses
ALTER TABLE public.match_video_breach_reports
  DROP CONSTRAINT IF EXISTS match_video_breach_reports_status_check;

ALTER TABLE public.match_video_breach_reports
  ADD CONSTRAINT match_video_breach_reports_status_check
  CHECK (status IN ('open', 'upheld', 'dismissed', 'approved', 'rejected'));

-- Multi-breach payload
ALTER TABLE public.match_video_breach_reports
  ADD COLUMN IF NOT EXISTS breaches jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Soften single-code column for legacy / first breach mirror
ALTER TABLE public.match_video_breach_reports
  ALTER COLUMN breach_tariff_code DROP NOT NULL;

COMMENT ON COLUMN public.match_video_breach_reports.breaches IS
  'Array of {code, note, label?} — each reported breach with required note.';

-- Backfill breaches from legacy single fields
UPDATE public.match_video_breach_reports r
SET breaches = jsonb_build_array(
  jsonb_build_object(
    'code', r.breach_tariff_code,
    'note', coalesce(nullif(btrim(r.note), ''), '(no note on legacy report)'),
    'label', coalesce(
      (SELECT t.label FROM public.competition_fine_tariff t WHERE t.code = r.breach_tariff_code),
      r.breach_tariff_code
    )
  )
)
WHERE (r.breaches IS NULL OR r.breaches = '[]'::jsonb)
  AND r.breach_tariff_code IS NOT NULL;

-- Map old statuses
UPDATE public.match_video_breach_reports SET status = 'approved' WHERE status = 'upheld';
UPDATE public.match_video_breach_reports SET status = 'rejected' WHERE status = 'dismissed';

-- One report ever per fixture side (keep earliest if duplicates)
DELETE FROM public.match_video_breach_reports a
USING public.match_video_breach_reports b
WHERE a.fixture_id = b.fixture_id
  AND a.side = b.side
  AND a.id > b.id;

DROP INDEX IF EXISTS match_video_breach_reports_open_uidx;

CREATE UNIQUE INDEX IF NOT EXISTS match_video_breach_reports_fixture_side_uidx
  ON public.match_video_breach_reports (fixture_id, side);

-- Which sides already have a report (for fixtures UI)
CREATE OR REPLACE FUNCTION public.match_video_reported_sides(
  p_fixture_ids bigint[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_fixture_ids IS NULL OR cardinality(p_fixture_ids) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'fixture_id', r.fixture_id,
        'side', r.side,
        'status', r.status,
        'report_id', r.id
      )
    )
    FROM public.match_video_breach_reports r
    WHERE r.fixture_id = ANY (p_fixture_ids)
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_reported_sides(bigint[]) TO authenticated;

-- Replace submit: multi-breach jsonb
DROP FUNCTION IF EXISTS public.match_video_submit_breach_report(bigint, text, text, text);

CREATE OR REPLACE FUNCTION public.match_video_submit_breach_report(
  p_fixture_id bigint,
  p_side text,
  p_breaches jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_side text := lower(btrim(p_side));
  v_f record;
  v_accused text;
  v_reporter_club text;
  v_id bigint;
  v_item jsonb;
  v_code text;
  v_note text;
  v_label text;
  v_clean jsonb := '[]'::jsonb;
  v_n int := 0;
  v_first_code text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_fixture_id IS NULL OR v_side NOT IN ('home', 'away') THEN
    RAISE EXCEPTION 'fixture_id and side (home|away) required';
  END IF;
  IF p_breaches IS NULL OR jsonb_typeof(p_breaches) <> 'array' OR jsonb_array_length(p_breaches) < 1 THEN
    RAISE EXCEPTION 'Select at least one breach';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.match_video_breach_reports r
    WHERE r.fixture_id = p_fixture_id AND r.side = v_side
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_reported',
      'message', 'This match side has already been reported and cannot be reported again.'
    );
  END IF;

  SELECT f.* INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
  IF v_f.status <> 'played' THEN
    RAISE EXCEPTION 'Fixture must be played';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.fixture_match_videos v
    WHERE v.fixture_id = p_fixture_id AND v.side = v_side
  ) THEN
    RAISE EXCEPTION 'No uploaded video on that side to report';
  END IF;

  v_accused := CASE
    WHEN v_side = 'home' THEN upper(btrim(v_f.home_club_short_name))
    ELSE upper(btrim(v_f.away_club_short_name))
  END;

  SELECT upper(btrim(c."ShortName"))
  INTO v_reporter_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  ORDER BY c."ShortName"
  LIMIT 1;

  IF v_reporter_club IS NULL THEN
    RAISE EXCEPTION 'You must own a club to submit a report';
  END IF;
  IF v_reporter_club = v_accused THEN
    RAISE EXCEPTION 'You cannot report your own club video';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_breaches)
  LOOP
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF v_code = '' THEN
      RAISE EXCEPTION 'Each breach must include a code';
    END IF;
    IF v_note = '' THEN
      RAISE EXCEPTION 'Every selected breach must include a note';
    END IF;

    SELECT t.label INTO v_label
    FROM public.competition_fine_tariff t
    WHERE t.code = v_code
      AND t.is_active
      AND t.direction = 'fine'
      AND t.category IN ('matchday', 'squad', 'manager')
      AND t.code <> 'match_video_missing';

    IF v_label IS NULL THEN
      RAISE EXCEPTION 'Invalid breach code: %', v_code;
    END IF;

    IF v_first_code IS NULL THEN
      v_first_code := v_code;
    END IF;

    v_clean := v_clean || jsonb_build_array(
      jsonb_build_object(
        'code', v_code,
        'note', v_note,
        'label', v_label
      )
    );
    v_n := v_n + 1;
  END LOOP;

  IF v_n < 1 THEN
    RAISE EXCEPTION 'Select at least one breach';
  END IF;

  BEGIN
    INSERT INTO public.match_video_breach_reports (
      season_id, fixture_id, side, accused_club_short_name,
      reporter_owner_id, reporter_club_short_name,
      breach_tariff_code, note, breaches, status
    ) VALUES (
      v_f.season_id,
      p_fixture_id,
      v_side,
      v_accused,
      v_uid,
      v_reporter_club,
      v_first_code,
      (v_clean->0->>'note'),
      v_clean,
      'open'
    )
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'already_reported',
        'message', 'This match side has already been reported and cannot be reported again.'
      );
  END;

  RETURN jsonb_build_object('ok', true, 'report_id', v_id, 'breach_count', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_submit_breach_report(bigint, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_match_video_list_breach_reports(
  p_status text DEFAULT 'open',
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text := lower(btrim(coalesce(p_status, 'open')));
  v_limit int := greatest(1, least(coalesce(p_limit, 100), 500));
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  -- Treat legacy upheld/dismissed as approved/rejected in filter
  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC)
    FROM (
      SELECT
        r.id,
        r.season_id,
        r.fixture_id,
        r.side,
        r.accused_club_short_name,
        r.reporter_club_short_name,
        r.reporter_owner_id,
        r.breach_tariff_code,
        r.breaches,
        jsonb_array_length(coalesce(r.breaches, '[]'::jsonb)) AS breach_count,
        r.note,
        CASE r.status
          WHEN 'upheld' THEN 'approved'
          WHEN 'dismissed' THEN 'rejected'
          ELSE r.status
        END AS status,
        r.created_at,
        r.reviewed_at,
        r.review_note,
        r.upheld_tariff_code,
        r.fine_applied_id,
        r.reward_ledger_id,
        f.matchday,
        f.gpsl_month,
        f.competition_type,
        f.division,
        f.cup_code,
        f.home_club_short_name,
        f.away_club_short_name,
        f.home_goals,
        f.away_goals,
        v.video_url
      FROM public.match_video_breach_reports r
      JOIN public.competition_fixtures f ON f.id = r.fixture_id
      LEFT JOIN public.fixture_match_videos v
        ON v.fixture_id = r.fixture_id AND v.side = r.side
      WHERE (
        v_status = 'all'
        OR r.status = v_status
        OR (v_status = 'approved' AND r.status IN ('approved', 'upheld'))
        OR (v_status = 'rejected' AND r.status IN ('rejected', 'dismissed'))
        OR (v_status = 'open' AND r.status = 'open')
      )
      ORDER BY r.created_at DESC
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_list_breach_reports(text, int) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_match_video_resolve_breach_report(
  p_report_id bigint,
  p_action text,
  p_tariff_code text DEFAULT NULL,
  p_review_note text DEFAULT NULL,
  p_amount_override numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_action text := lower(btrim(p_action));
  v_uid uuid := auth.uid();
  v_r public.match_video_breach_reports%ROWTYPE;
  v_item jsonb;
  v_code text;
  v_note text;
  v_apply jsonb;
  v_fines jsonb := '[]'::jsonb;
  v_reward_id bigint;
  v_reward numeric := 2000;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  -- Normalise aliases
  IF v_action IN ('uphold', 'ok', 'approve') THEN
    v_action := 'approve';
  ELSIF v_action IN ('dismiss', 'reject') THEN
    v_action := 'reject';
  END IF;

  IF v_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'action must be approve or reject';
  END IF;

  SELECT * INTO v_r
  FROM public.match_video_breach_reports
  WHERE id = p_report_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Report not found';
  END IF;
  IF v_r.status <> 'open' THEN
    RAISE EXCEPTION 'Report already resolved';
  END IF;

  IF v_action = 'reject' THEN
    UPDATE public.match_video_breach_reports
    SET status = 'rejected',
        reviewed_at = now(),
        reviewed_by = v_uid,
        review_note = nullif(btrim(coalesce(p_review_note, '')), '')
    WHERE id = p_report_id;

    RETURN jsonb_build_object('ok', true, 'status', 'rejected', 'report_id', p_report_id);
  END IF;

  -- Approve: fine each reported breach, then reward reporter
  FOR v_item IN
    SELECT * FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(coalesce(v_r.breaches, '[]'::jsonb)) = 'array'
             AND jsonb_array_length(v_r.breaches) > 0
          THEN v_r.breaches
        ELSE jsonb_build_array(
          jsonb_build_object(
            'code', coalesce(nullif(btrim(coalesce(p_tariff_code, '')), ''), v_r.breach_tariff_code),
            'note', coalesce(v_r.note, format('Match video breach report #%s', p_report_id))
          )
        )
      END
    )
  LOOP
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF v_code = '' THEN
      CONTINUE;
    END IF;

    BEGIN
      v_apply := public.competition_apply_club_fine_tariff(
        v_r.accused_club_short_name,
        v_code,
        p_amount_override,
        coalesce(
          nullif(v_note, ''),
          format('Match video breach report #%s', p_report_id)
        ),
        v_r.fixture_id,
        v_r.season_id
      );
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'apply', v_apply)
      );
    EXCEPTION WHEN OTHERS THEN
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'error', SQLERRM)
      );
    END;
  END LOOP;

  BEGIN
    PERFORM public.owner_wallet_ensure(v_r.reporter_owner_id);
    v_reward_id := public._post_owner_ledger_internal(
      v_r.reporter_owner_id,
      'match_video_report_reward',
      v_reward,
      format('Match video report approved (#%s)', p_report_id),
      jsonb_build_object(
        'source', 'match_video_breach_report',
        'report_id', p_report_id,
        'fixture_id', v_r.fixture_id
      ),
      v_r.season_id,
      true
    );
  EXCEPTION WHEN OTHERS THEN
    v_reward_id := NULL;
  END;

  UPDATE public.match_video_breach_reports
  SET status = 'approved',
      reviewed_at = now(),
      reviewed_by = v_uid,
      review_note = nullif(btrim(coalesce(p_review_note, '')), ''),
      upheld_tariff_code = coalesce(v_r.breaches->0->>'code', v_r.breach_tariff_code),
      fine_applied_id = nullif(v_fines->0->'apply'->>'applied_id', '')::bigint,
      fine_ledger_id = nullif(v_fines->0->'apply'->>'ledger_id', '')::bigint,
      reward_ledger_id = v_reward_id
  WHERE id = p_report_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'approved',
    'report_id', p_report_id,
    'fines', v_fines,
    'reward_ledger_id', v_reward_id,
    'reward_amount', v_reward
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
