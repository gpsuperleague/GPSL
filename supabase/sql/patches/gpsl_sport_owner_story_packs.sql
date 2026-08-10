-- =============================================================================
-- GPSL Sport: varied owner-takeover stories (no identical welcome bodies)
--
-- Cause: gpsl_sport_build_owner_story used one fixed body per assign_source.
-- After a reset, almost everyone is club_welcome → same paragraph, only names change.
--
-- Fix: use owner_takeover packs (headline + pull quote + body), unique per owner
-- in the same edition via exclude list. Requires gpsl_sport_template_packs.sql.
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.gpsl_sport_build_owner_story(text, jsonb, text);

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_owner_story(
  p_seed text,
  p_owner jsonb,
  p_month_label text,
  p_exclude_pack_ids text[] DEFAULT '{}'::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_short text := p_owner->>'club_short';
  v_club_name text := coalesce(p_owner->>'club_name', v_club_short);
  v_owner_tag text := coalesce(p_owner->>'owner_tag', 'New owner');
  v_headline text;
  v_body text;
  v_pull text;
  v_byline text;
  v_source text := coalesce(p_owner->>'assign_source', 'club_assignment');
  v_vars jsonb;
  v_pack jsonb;
  v_seed text := coalesce(p_seed, '') || ':' || coalesce(v_club_short, 'club') || ':' || coalesce(v_owner_tag, 'owner');
  v_exclude text[] := coalesce(p_exclude_pack_ids, '{}'::text[]);
BEGIN
  v_vars := jsonb_build_object(
    'owner', v_owner_tag,
    'club', v_club_name,
    'month', coalesce(p_month_label, 'pre-season'),
    'club_short', coalesce(v_club_short, '')
  );

  -- Prefer source-flavoured packs when available, then general owner_takeover bank
  IF to_regprocedure(
       'public.gpsl_sport_compose_story_from_packs(text,text,jsonb,bigint,text[],integer)'
     ) IS NOT NULL THEN
    IF v_source = 'club_auction' THEN
      v_pack := public.gpsl_sport_compose_story_from_packs(
        'owner_takeover', v_seed || ':auction', v_vars, NULL,
        -- Bias: try auction pack first by excluding nothing but seeding auction;
        -- still from same scenario bank (packs include own_auction_win).
        v_exclude, 3
      );
    ELSIF v_source IN ('admin_assign', 'owner_assignment', 'club_assignment') THEN
      v_pack := public.gpsl_sport_compose_story_from_packs(
        'owner_takeover', v_seed || ':assign', v_vars, NULL, v_exclude, 3
      );
    ELSE
      v_pack := public.gpsl_sport_compose_story_from_packs(
        'owner_takeover', v_seed || ':welcome', v_vars, NULL, v_exclude, 3
      );
    END IF;

    IF v_pack IS NULL THEN
      v_pack := public.gpsl_sport_compose_story_from_packs(
        'owner_takeover', v_seed, v_vars, NULL, v_exclude, 3
      );
    END IF;
  END IF;

  IF v_pack IS NOT NULL THEN
    v_headline := v_pack->>'headline';
    v_body := v_pack->>'body';
    v_pull := coalesce(nullif(v_pack->>'subhead', ''), '"The work starts now."');
    v_byline := 'By GPSL Sport owner desk · ' || v_club_name;

    RETURN jsonb_build_object(
      'kicker', 'New owner',
      'headline', v_headline,
      'body', v_body,
      'pull_quote', v_pull,
      'byline', v_byline,
      'story_kind', 'owner_takeover',
      'club_short', v_club_short,
      'club_name', v_club_name,
      'owner_tag', v_owner_tag,
      'owner_id', p_owner->>'owner_id',
      'pack_id', v_pack->>'pack_id',
      'assign_source', v_source
    );
  END IF;

  -- Fallback (packs not installed): still vary headline/body/pull by seed+club
  v_headline := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(v_seed || ':oh', ARRAY[
      '{{OWNER}} TAKES THE HELM AT {{CLUB}}',
      'NEW ERA AT {{CLUB}} — {{OWNER}} INSTALLED',
      '{{CLUB}} WELCOME {{OWNER}}',
      'KEYS HANDED OVER — {{OWNER}} AT {{CLUB}}',
      '{{OWNER}} DROPS INTO THE {{CLUB}} HOT SEAT',
      'GROUP CHATS NOTICE: {{OWNER}} HAS {{CLUB}}'
    ]),
    v_vars
  );

  v_body := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(v_seed || ':ob', ARRAY[
      E'{{OWNER}} is in at {{CLUB}}. Not a rumour — the link is live, the inbox is open, and pre-season {{MONTH}} is already on the clock.',
      E'{{CLUB}} have a new name above the door: {{OWNER}}. Boardroom seat taken, transfer budget live. Pre-season is short. Ambition usually is not.',
      E'Official welcome confirmed for {{OWNER}} at {{CLUB}} this {{MONTH}}. The takeover chatter can stop — they are in.',
      E'{{OWNER}} has the keys at {{CLUB}}. Stadium costs settled, squad inherited, expectations waiting in the inbox.',
      E'Another GPSL hot seat filled: {{OWNER}} → {{CLUB}}. {{MONTH}} pre-season is the calm before the inbox storms.',
      E'Call it a project or a privilege — {{OWNER}} now runs {{CLUB}}. The welcome message is the easy part.'
    ]),
    v_vars
  );

  v_pull := public.gpsl_sport_pick_template(v_seed || ':op', ARRAY[
    '"This is a special club — I cannot wait to get started."',
    '"The squad has quality. My job is to unlock it."',
    '"I have followed GPSL for years. Now it is my turn."',
    '"Expect ambition. I did not come here to finish mid-table."',
    '"Build something. That is the brief."',
    '"No honeymoon. Just work."'
  ]);

  v_byline := 'By GPSL Sport owner desk · ' || v_club_name;

  RETURN jsonb_build_object(
    'kicker', 'New owner',
    'headline', v_headline,
    'body', v_body,
    'pull_quote', v_pull,
    'byline', v_byline,
    'story_kind', 'owner_takeover',
    'club_short', v_club_short,
    'club_name', v_club_name,
    'owner_tag', v_owner_tag,
    'owner_id', p_owner->>'owner_id',
    'assign_source', v_source
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_owner_story(text, jsonb, text, text[])
  TO authenticated, service_role;
