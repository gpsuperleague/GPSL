-- =============================================================================
-- Fix match video amounts RPC (STABLE+INSERT) + ledger labels 48h → 72h
-- (2026-09-14)
-- Safe re-run.
-- =============================================================================

-- Ensure grace setting
UPDATE public.gpsl_discord_match_videos_settings
SET
  missing_fine_grace_hours = 72,
  updated_at = now()
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.match_video_missing_fine_grace_hours()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v int;
BEGIN
  SELECT s.missing_fine_grace_hours INTO v
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;
  RETURN greatest(1, coalesce(v, 72));
END;
$function$;

-- Read-only get amounts (no INSERT — that caused STABLE volatility error)
CREATE OR REPLACE FUNCTION public.admin_match_video_get_amounts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_payout numeric;
  v_fine numeric;
  v_grace int;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT
    s.payout_amount,
    s.missing_fine_amount,
    s.missing_fine_grace_hours
  INTO v_payout, v_fine, v_grace
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'payout_amount', coalesce(v_payout, 200000),
    'missing_fine_amount', coalesce(v_fine, 500000),
    'missing_fine_grace_hours', coalesce(v_grace, 72)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_match_video_set_amounts(
  p_payout_amount numeric DEFAULT NULL,
  p_missing_fine_amount numeric DEFAULT NULL,
  p_missing_fine_grace_hours int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_payout numeric;
  v_fine numeric;
  v_grace int;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  INSERT INTO public.gpsl_discord_match_videos_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  SELECT payout_amount, missing_fine_amount, missing_fine_grace_hours
  INTO v_payout, v_fine, v_grace
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  IF p_payout_amount IS NOT NULL THEN
    IF p_payout_amount <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'payout_amount must be > 0');
    END IF;
    v_payout := round(p_payout_amount);
  END IF;

  IF p_missing_fine_amount IS NOT NULL THEN
    IF p_missing_fine_amount < 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_fine_amount must be >= 0');
    END IF;
    v_fine := round(p_missing_fine_amount);
  END IF;

  IF p_missing_fine_grace_hours IS NOT NULL THEN
    IF p_missing_fine_grace_hours < 1 OR p_missing_fine_grace_hours > 24 * 30 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'grace hours must be 1–720');
    END IF;
    v_grace := p_missing_fine_grace_hours;
  ELSE
    v_grace := coalesce(v_grace, 72);
  END IF;

  UPDATE public.gpsl_discord_match_videos_settings
  SET
    payout_amount = v_payout,
    missing_fine_amount = v_fine,
    missing_fine_grace_hours = v_grace,
    updated_at = now()
  WHERE id = 1;

  UPDATE public.competition_fine_tariff
  SET amount = v_fine
  WHERE code = 'match_video_missing';

  RETURN public.admin_match_video_get_amounts();
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_video_get_amounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_match_video_get_amounts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_get_amounts() TO service_role;
REVOKE ALL ON FUNCTION public.admin_match_video_set_amounts(numeric, numeric, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_match_video_set_amounts(numeric, numeric, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_set_amounts(numeric, numeric, int) TO service_role;

-- Rewrite existing ledger / fine notes that still say 48h
UPDATE public.competition_finance_ledger l
SET description = regexp_replace(
  regexp_replace(l.description, 'within 48\s*h', 'within 72h', 'gi'),
  'within 48 hours',
  'within 72 hours',
  'gi'
)
WHERE l.entry_type = 'gov_fine_compensation'
  AND (
    (l.metadata->>'tariff_code') = 'match_video_missing'
    OR l.description ILIKE '%missing match video%'
  )
  AND l.description ~* '48\s*h';

UPDATE public.competition_fine_applied fa
SET
  description = regexp_replace(
    regexp_replace(coalesce(fa.description, ''), 'within 48\s*h', 'within 72h', 'gi'),
    'within 48 hours',
    'within 72 hours',
    'gi'
  ),
  note = regexp_replace(
    regexp_replace(coalesce(fa.note, ''), 'within 48\s*h', 'within 72h', 'gi'),
    'within 48 hours',
    'within 72 hours',
    'gi'
  )
WHERE fa.tariff_code = 'match_video_missing'
  AND (
    coalesce(fa.description, '') ~* '48\s*h'
    OR coalesce(fa.note, '') ~* '48\s*h'
  );

UPDATE public.competition_fine_tariff
SET
  label = 'Missing match video (after 72h grace)',
  updated_at = now()
WHERE code = 'match_video_missing';

NOTIFY pgrst, 'reload schema';
