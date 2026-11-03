-- Fix: friendlies gate pay crashed because club_owner_id_for_short() was missing.
-- Symptom: confirmed friendlies show "No payout" with
--   left/right_skipped_reason = 'Pay error: function public.club_owner_id_for_short(text) does not exist'
-- Restore the helper, then retro-pay failed sides (idempotent via paid_* / ledger).

CREATE OR REPLACE FUNCTION public.club_owner_id_for_short(p_club text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.owner_id
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = upper(btrim(coalesce(p_club, '')))
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.club_owner_id_for_short(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_owner_id_for_short(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_repair_owner_fn_pay_failures(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  r record;
  v_pay jsonb;
  v_paid numeric;
  v_skip text;
  v_scoreline text;
  v_left_fixed int := 0;
  v_right_fixed int := 0;
  v_left_still int := 0;
  v_right_still int := 0;
BEGIN
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no season');
  END IF;

  IF to_regprocedure('public.gpsl_friendlies_pay_club(bigint,text,text,bigint,text)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'gpsl_friendlies_pay_club missing');
  END IF;

  FOR r IN
    SELECT f.*
    FROM public.gpsl_friendlies f
    WHERE f.season_id = v_season
      AND (
        (
          coalesce(f.paid_left, 0) = 0
          AND coalesce(f.left_skipped_reason, '') ILIKE '%club_owner_id_for_short%'
        )
        OR (
          coalesce(f.paid_right, 0) = 0
          AND coalesce(f.right_skipped_reason, '') ILIKE '%club_owner_id_for_short%'
        )
      )
    ORDER BY f.confirmed_at NULLS LAST, f.id
  LOOP
    v_scoreline := format(
      '%s %s - %s %s',
      r.club_left, r.score_left, r.score_right, r.club_right
    );

    IF coalesce(r.paid_left, 0) = 0
       AND coalesce(r.left_skipped_reason, '') ILIKE '%club_owner_id_for_short%' THEN
      BEGIN
        v_pay := public.gpsl_friendlies_pay_club(
          v_season, r.gpsl_month, r.club_left, r.id, v_scoreline
        );
        v_paid := coalesce((v_pay ->> 'paid')::numeric, 0);
        v_skip := v_pay ->> 'skipped';
        UPDATE public.gpsl_friendlies
        SET paid_left = v_paid,
            left_skipped_reason = v_skip
        WHERE id = r.id;
        IF v_paid > 0 THEN
          v_left_fixed := v_left_fixed + 1;
        ELSE
          v_left_still := v_left_still + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        UPDATE public.gpsl_friendlies
        SET left_skipped_reason = left('Pay error: ' || SQLERRM, 200)
        WHERE id = r.id;
        v_left_still := v_left_still + 1;
      END;
    END IF;

    IF coalesce(r.paid_right, 0) = 0
       AND coalesce(r.right_skipped_reason, '') ILIKE '%club_owner_id_for_short%' THEN
      BEGIN
        v_pay := public.gpsl_friendlies_pay_club(
          v_season, r.gpsl_month, r.club_right, r.id, v_scoreline
        );
        v_paid := coalesce((v_pay ->> 'paid')::numeric, 0);
        v_skip := v_pay ->> 'skipped';
        UPDATE public.gpsl_friendlies
        SET paid_right = v_paid,
            right_skipped_reason = v_skip
        WHERE id = r.id;
        IF v_paid > 0 THEN
          v_right_fixed := v_right_fixed + 1;
        ELSE
          v_right_still := v_right_still + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        UPDATE public.gpsl_friendlies
        SET right_skipped_reason = left('Pay error: ' || SQLERRM, 200)
        WHERE id = r.id;
        v_right_still := v_right_still + 1;
      END;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'left_paid', v_left_fixed,
    'right_paid', v_right_fixed,
    'left_still_unpaid', v_left_still,
    'right_still_unpaid', v_right_still
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_repair_owner_fn_pay_failures(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_repair_owner_fn_pay_failures(bigint)
  TO service_role, authenticated;

SELECT public.gpsl_friendlies_repair_owner_fn_pay_failures(NULL) AS repair_result;

-- Snapshot after repair
SELECT
  count(*) FILTER (WHERE coalesce(paid_left,0)=0 AND left_skipped_reason ILIKE '%club_owner%') AS left_still_owner_err,
  count(*) FILTER (WHERE coalesce(paid_right,0)=0 AND right_skipped_reason ILIKE '%club_owner%') AS right_still_owner_err,
  count(*) FILTER (WHERE coalesce(paid_left,0)>0) AS left_paid_rows,
  count(*) FILTER (WHERE coalesce(paid_right,0)>0) AS right_paid_rows
FROM public.gpsl_friendlies
WHERE season_id = (SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
  AND lower(gpsl_month) = 'september';
