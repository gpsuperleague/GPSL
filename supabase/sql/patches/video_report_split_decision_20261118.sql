-- Staff can uphold some breaches on one report and dismiss the rest.
-- Only upheld breaches are fined, replayed, or docked points.
-- p_uphold NULL keeps the old behaviour: every breach is upheld.

DO $split$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure(
    'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean,integer[])'
  ) IS NOT NULL THEN
    RAISE NOTICE 'resolve already accepts p_uphold';
    RETURN;
  END IF;

  v_def := replace(
    pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'::regprocedure),
    E'\r\n', E'\n'
  );

  v_old := 'p_replay boolean DEFAULT NULL::boolean)';
  v_new := 'p_replay boolean DEFAULT NULL::boolean, p_uphold integer[] DEFAULT NULL::integer[])';
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'resolve signature not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := 'v_reward numeric := 2000;';
  v_new := E'v_reward numeric := 2000;\n  v_idx int := 0;\n  v_marked jsonb := ''[]''::jsonb;';
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'reward declare not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$
  LOOP
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF v_code = '' THEN
      CONTINUE;
    END IF;$old$, E'\r\n', E'\n');
  v_new := replace($new$
  LOOP
    v_idx := v_idx + 1;
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF p_uphold IS NOT NULL AND NOT ((v_idx - 1) = ANY (p_uphold)) THEN
      v_marked := v_marked || jsonb_build_array(
        coalesce(v_item, '{}'::jsonb) || jsonb_build_object('decision', 'dismissed')
      );
      CONTINUE;
    END IF;
    v_marked := v_marked || jsonb_build_array(
      coalesce(v_item, '{}'::jsonb) || jsonb_build_object('decision', 'upheld')
    );
    IF v_code = '' THEN
      CONTINUE;
    END IF;$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'breach loop not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '  -- reward once per match for this owner; the other video is still approved';
  v_new := replace($new$
  IF p_uphold IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_marked) m WHERE m->>'decision' = 'upheld'
  ) THEN
    RAISE EXCEPTION 'Choose at least one breach to uphold, or reject the report';
  END IF;

  -- reward once per match for this owner; the other video is still approved$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'reward comment not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '  SET status = ''approved'',';
  v_new := '  SET status = ''approved'', breaches = CASE WHEN jsonb_typeof(v_marked) = ''array'' AND jsonb_array_length(v_marked) > 0 THEN v_marked ELSE breaches END,';
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'approve update not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := 'upheld_tariff_code = coalesce(v_r.breaches->0->>''code'', v_r.breach_tariff_code),';
  v_new := 'upheld_tariff_code = coalesce((SELECT m->>''code'' FROM jsonb_array_elements(v_marked) m WHERE coalesce(m->>''decision'', ''upheld'') = ''upheld'' AND coalesce(m->>''code'', '''') <> '''' LIMIT 1), v_r.breach_tariff_code),';
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'upheld code not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
END
$split$;

DROP FUNCTION IF EXISTS public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric, boolean);

GRANT EXECUTE ON FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric, boolean, integer[])
  TO anon, authenticated, service_role;

DO $news$
DECLARE
  v_def text;
  v_old text := $old$
        SELECT b->>'code'
        FROM jsonb_array_elements(coalesce(v_r.breaches, '[]'::jsonb)) b$old$;
  v_new text := $new$
        SELECT b->>'code'
        FROM jsonb_array_elements(coalesce(v_r.breaches, '[]'::jsonb)) b
        WHERE coalesce(b->>'decision', 'upheld') <> 'dismissed'$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_video_report_post_upheld_news(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('decision'', ''upheld'') <> ''dismissed''' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'upheld news breach list not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$news$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'split', to_regprocedure(
    'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean,integer[])'
  ) IS NOT NULL,
  'old_gone', to_regprocedure(
    'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'
  ) IS NULL,
  'skips_dismissed', position(
    'decision'', ''dismissed'''
    IN pg_get_functiondef(
      'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean,integer[])'::regprocedure
    )
  ) > 0,
  'news_skips_dismissed', position(
    'dismissed'
    IN pg_get_functiondef('public.match_video_report_post_upheld_news(bigint)'::regprocedure)
  ) > 0
) AS check;
