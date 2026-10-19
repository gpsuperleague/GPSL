-- =============================================================================
-- Fix: club_holiday_book fails — inbox type 'owner_holiday' missing from
-- competition_inbox_message_type_check (added by holiday inbox trigger).
-- Safe re-run.
-- =============================================================================

DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL AND position('''owner_holiday''' IN v_def) > 0 THEN
    RAISE NOTICE 'owner_holiday already allowed on competition_inbox';
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'owner_holiday'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

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

  RAISE NOTICE 'Added owner_holiday to competition_inbox_message_type_check';
END;
$inbox_types$;

NOTIFY pgrst, 'reload schema';
