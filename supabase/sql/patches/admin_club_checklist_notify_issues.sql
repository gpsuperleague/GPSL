-- =============================================================================
-- Admin: notify club owners of season checklist deficiencies
-- Call from admin_club_checklist.html (client builds issue text per club).
-- Safe to re-run.
-- =============================================================================

DO $inbox_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT 'club_checklist_issues'
  ) s;

  IF v_list IS NULL OR btrim(v_list) = '' THEN
    RAISE EXCEPTION 'No inbox message types to install';
  END IF;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

CREATE OR REPLACE FUNCTION public.admin_notify_club_checklist_issues(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_club text;
  v_body text;
  v_title text;
  v_season_id bigint;
  v_sent int := 0;
  v_skipped int := 0;
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'No checklist notifications to send';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_club := nullif(btrim(coalesce(v_item ->> 'club_short_name', '')), '');
    v_body := nullif(btrim(coalesce(v_item ->> 'body', '')), '');
    v_title := coalesce(
      nullif(btrim(coalesce(v_item ->> 'title', '')), ''),
      'Club checklist — issues to fix'
    );

    IF v_club IS NULL OR v_body IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public."Clubs" c
      WHERE c."ShortName" = v_club
        AND c.owner_id IS NOT NULL
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_id := public.owner_inbox_send(
      'club_checklist_issues',
      v_title,
      v_body,
      v_club,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      'squad.html',
      'checklist_issues:' || v_club || ':' || gen_random_uuid()::text,
      NULL,
      v_season_id
    );

    IF v_id IS NOT NULL THEN
      v_sent := v_sent + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'skipped', v_skipped,
    'season_id', v_season_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_notify_club_checklist_issues(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
