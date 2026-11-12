-- Inbox every current owner a link to Getting started. Safe re-run (deduped).

DO $inbox$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL AND position('''getting_started''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'getting_started'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox$;

SELECT public.owner_inbox_notify_all_clubs(
  'getting_started',
  'Getting started',
  E'The owner''s guide is on Getting started.\n\nIt covers choosing a club, Handpick, the squad rules, GPSL months, arranging a match, recording it, and the fines. The season runs August to December, then January to May. The month changes on Thursday at 7pm UK.',
  'getting_started.html',
  'getting_started:20261112',
  NULL
) AS sent;
