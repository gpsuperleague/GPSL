-- =============================================================================
-- Owner "Ready for August" checklist + per-match pre-match recording ticks.
--
--   owner_ready_ticks                 owner self-ticks (season items + per fixture)
--   gpsl_owner_ready_items(club, season)   internal: builds the item list
--   owner_season_ready_checklist()    owner dashboard panel (hidden once GPSL
--                                     August unlocks)
--   owner_ready_tick(key, ticked, fixture)  tick / untick
--   admin_owner_ready_summary()       admin Club Checklist "Ready" column
--
-- Squad rules match admin_club_season_checklist (24 / 8 HG / 1 GK / 5 U21 /
-- star cap). Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.owner_ready_ticks (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL,
  season_id bigint,
  fixture_id bigint,
  item_key text NOT NULL,
  ticked_at timestamptz NOT NULL DEFAULT now(),
  ticked_by uuid DEFAULT auth.uid()
);

CREATE UNIQUE INDEX IF NOT EXISTS owner_ready_ticks_uniq
  ON public.owner_ready_ticks (club_short_name, coalesce(season_id, 0), coalesce(fixture_id, 0), item_key);
CREATE INDEX IF NOT EXISTS owner_ready_ticks_fixture_idx
  ON public.owner_ready_ticks (fixture_id) WHERE fixture_id IS NOT NULL;

ALTER TABLE public.owner_ready_ticks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_ready_ticks_read ON public.owner_ready_ticks;
CREATE POLICY owner_ready_ticks_read ON public.owner_ready_ticks
  FOR SELECT TO authenticated
  USING (
    upper(club_short_name) = upper(coalesce(public.my_club_shortname(), ''))
    OR public.is_gpsl_admin()
  );
REVOKE ALL ON public.owner_ready_ticks FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.owner_ready_ticks TO authenticated;

-- Keys owners may tick
CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_tick_keys(p_fixture boolean)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN p_fixture
    THEN ARRAY['rec_started', 'rec_room_settings', 'rec_prematch_config', 'rec_squad_tactics',
               'rec_pause_pa', 'rec_hud_on', 'rec_post_match']
    ELSE ARRAY['read_matchday_checklist', 'can_record', 'know_match_settings',
               'know_squad_tactics', 'know_kits_stadium']
  END;
$$;

-- ---------------------------------------------------------------------------
-- Item builder (internal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_items(p_club text, p_season bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club));
  v_items jsonb := '[]'::jsonb;
  v_star_min smallint := 79;
  v_ooo text;
  v_size int; v_gk int; v_u21 int; v_hg int; v_stars int; v_cap int;
  v_mgr text; v_reg_tag text; v_club_tag text; v_slots int := 0;
  v_home_total int := 0; v_home_done int := 0; v_replies int := 0;
  v_sponsor boolean := false;
  r record;
  v_proposed boolean;
  v_ticks text[];
BEGIN
  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_star_min := public.club_squad_star_min_rating();
  ELSE
    SELECT coalesce(gs.star_tax_min_rating, 79) INTO v_star_min
    FROM public.global_settings gs WHERE gs.id = 1;
  END IF;

  BEGIN
    SELECT d.player_id INTO v_ooo
    FROM public.club_squad_player_designations d
    WHERE upper(d.club_short_name) = v_club AND d.designation = 'one_of_our_own'
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN v_ooo := NULL;
  END;

  SELECT
    count(*)::int,
    count(*) FILTER (WHERE upper(btrim(coalesce(p."Position"::text, ''))) IN ('GK', 'GOALKEEPER'))::int,
    count(*) FILTER (
      WHERE p."Age" IS NOT NULL AND btrim(p."Age"::text) ~ '^[0-9.]+$'
        AND btrim(p."Age"::text)::numeric <= 21
    )::int,
    count(*) FILTER (
      WHERE public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
        AND public.normalize_nation_key(p."Nation") <> ''
    )::int,
    count(*) FILTER (
      WHERE nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), '')::int >= v_star_min
        AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo)
    )::int
  INTO v_size, v_gk, v_u21, v_hg, v_stars
  FROM public."Players" p
  JOIN public."Clubs" c ON c."ShortName" = p."Contracted_Team"
  WHERE upper(p."Contracted_Team") = v_club;

  BEGIN
    SELECT count(*)::int INTO v_gk
    FROM public."Players" p
    WHERE upper(p."Contracted_Team") = v_club
      AND public.international_player_pool_position_group(p."Position") = 'gk';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    v_cap := public.club_squad_star_cap(v_club)::int;
  EXCEPTION WHEN OTHERS THEN
    SELECT CASE WHEN ccs.division = 'superleague' THEN 3 ELSE 2 END INTO v_cap
    FROM public.competition_club_seasons ccs
    WHERE upper(ccs.club_short_name) = v_club AND ccs.season_id = p_season;
    v_cap := coalesce(v_cap, 2);
  END;

  SELECT m.name INTO v_mgr
  FROM public."Managers" m
  WHERE upper(nullif(btrim(m.contracted_club), '')) = v_club
  ORDER BY m.id LIMIT 1;

  SELECT
    public.normalize_owner_discord_tag(r2.owner_tag),
    public.normalize_owner_discord_tag(c.owner)
  INTO v_reg_tag, v_club_tag
  FROM public."Clubs" c
  LEFT JOIN public.gpsl_owner_registry r2 ON r2.owner_id = c.owner_id
  WHERE upper(c."ShortName") = v_club;

  BEGIN
    SELECT count(*)::int INTO v_slots
    FROM public.club_owner_availability_slot s
    WHERE s.season_id = p_season AND upper(s.club_short_name) = v_club;
  EXCEPTION WHEN OTHERS THEN v_slots := 0;
  END;

  -- August + September fixtures (league + drawn cup ties) where we are home
  FOR r IN
    SELECT f.id, s.status AS sched_status
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND lower(btrim(f.gpsl_month)) IN ('august', 'september')
      AND upper(btrim(f.home_club_short_name)) = v_club
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
  LOOP
    v_home_total := v_home_total + 1;
    IF coalesce(r.sched_status, 'unscheduled') = 'agreed' THEN
      v_proposed := true;
    ELSE
      BEGIN
        v_proposed := public.match_schedule_home_has_proposed(r.id, now());
      EXCEPTION WHEN OTHERS THEN
        v_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
      END;
    END IF;
    IF v_proposed THEN v_home_done := v_home_done + 1; END IF;
  END LOOP;

  SELECT count(*)::int INTO v_replies
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.season_id = p_season
    AND f.status = 'scheduled'
    AND s.status = 'negotiating'
    AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = v_club;

  BEGIN
    SELECT EXISTS (
      SELECT 1 FROM public.club_commercial_sponsorships sp
      WHERE upper(sp.club_short_name) = v_club
        AND sp.start_season_id <= p_season
        AND sp.start_season_id + greatest(sp.seasons_total, 1) > p_season
    ) INTO v_sponsor;
  EXCEPTION WHEN OTHERS THEN v_sponsor := false;
  END;

  SELECT coalesce(array_agg(t.item_key), ARRAY[]::text[]) INTO v_ticks
  FROM public.owner_ready_ticks t
  WHERE upper(t.club_short_name) = v_club AND t.season_id = p_season AND t.fixture_id IS NULL;

  v_items := jsonb_build_array(
    -- Squad
    jsonb_build_object('key', 'squad_size', 'group', 'Squad', 'kind', 'auto', 'href', 'squad.html',
      'label', 'At least 24 players (max 28)', 'detail', format('You have %s', v_size),
      'done', v_size BETWEEN 24 AND 28),
    jsonb_build_object('key', 'hg', 'group', 'Squad', 'kind', 'auto', 'href', 'squad.html',
      'label', 'At least 8 homegrown players', 'detail', format('You have %s', v_hg),
      'done', v_hg >= 8),
    jsonb_build_object('key', 'gk', 'group', 'Squad', 'kind', 'auto', 'href', 'squad.html',
      'label', 'At least 1 goalkeeper', 'detail', format('You have %s', v_gk),
      'done', v_gk >= 1),
    jsonb_build_object('key', 'u21', 'group', 'Squad', 'kind', 'auto', 'href', 'squad.html',
      'label', 'At least 5 U21 players', 'detail', format('You have %s', v_u21),
      'done', v_u21 >= 5),
    jsonb_build_object('key', 'stars', 'group', 'Squad', 'kind', 'auto', 'href', 'squad.html',
      'label', 'Star players within your cap', 'detail', format('%s of %s', v_stars, v_cap),
      'done', v_stars <= v_cap),
    -- Club set-up
    jsonb_build_object('key', 'manager', 'group', 'Club set-up', 'kind', 'auto', 'href', 'manager_listings.html',
      'label', 'Manager signed', 'detail', coalesce(v_mgr, 'No manager yet'),
      'done', v_mgr IS NOT NULL),
    jsonb_build_object('key', 'discord_tag', 'group', 'Club set-up', 'kind', 'auto', 'href', 'owner_details.html',
      'label', 'Discord tag linked',
      'detail', CASE WHEN v_reg_tag IS NULL OR v_club_tag IS NULL THEN 'Missing — ask an admin'
                     WHEN v_reg_tag <> v_club_tag THEN 'Does not match your club — ask an admin'
                     ELSE '@' || v_reg_tag END,
      'done', v_reg_tag IS NOT NULL AND v_reg_tag = v_club_tag),
    jsonb_build_object('key', 'availability', 'group', 'Club set-up', 'kind', 'auto', 'href', 'owner_details.html',
      'label', 'Match availability set for this season',
      'detail', CASE WHEN v_slots > 0 THEN format('%s time slots', v_slots) ELSE 'Not set yet' END,
      'done', v_slots > 0),
    jsonb_build_object('key', 'sponsor', 'group', 'Club set-up', 'kind', 'recommended', 'href', 'stadium.html',
      'label', 'Main sponsor chosen (recommended)',
      'detail', CASE WHEN v_sponsor THEN 'Signed'
                     ELSE 'Optional — choose on the Stadium page by the end of the month you took over, or one is picked for you' END,
      'done', v_sponsor),
    -- Fixtures
    jsonb_build_object('key', 'aug_sep_proposed', 'group', 'Fixtures', 'kind', 'auto', 'href', 'fixture_schedule.html',
      'label', 'August & September home matches proposed (incl. cup ties)',
      'detail', CASE WHEN v_home_total = 0 THEN 'None to propose yet'
                     ELSE format('%s of %s proposed', v_home_done, v_home_total) END,
      'done', v_home_done >= v_home_total),
    jsonb_build_object('key', 'replies', 'group', 'Fixtures', 'kind', 'auto', 'href', 'inbox.html',
      'label', 'Replied to every match proposal sent to you',
      'detail', CASE WHEN v_replies = 0 THEN 'All replied' ELSE format('%s waiting for your reply', v_replies) END,
      'done', v_replies = 0),
    -- Matchday ready (self-tick)
    jsonb_build_object('key', 'read_matchday_checklist', 'group', 'Matchday ready', 'kind', 'tick',
      'href', 'learning_gpsl.html#matchday-checklist',
      'label', 'I''ve read the Matchday checklist', 'done', 'read_matchday_checklist' = ANY (v_ticks)),
    jsonb_build_object('key', 'can_record', 'group', 'Matchday ready', 'kind', 'tick',
      'href', 'https://discord.com/channels/1483974134361886802/1549828547814891550',
      'label', 'I can record my matches and upload the video', 'done', 'can_record' = ANY (v_ticks)),
    jsonb_build_object('key', 'know_match_settings', 'group', 'Matchday ready', 'kind', 'tick',
      'label', 'I know the match settings: 10 min, injuries OFF, 5 subs, 3 sub intervals, form Random, PA3 or PA4 only',
      'done', 'know_match_settings' = ANY (v_ticks)),
    jsonb_build_object('key', 'know_squad_tactics', 'group', 'Matchday ready', 'kind', 'tick',
      'label', 'I know the squad & tactics rules: GP manager only, default formation for sub tactic / fluid, blank player instructions',
      'done', 'know_squad_tactics' = ANY (v_ticks)),
    jsonb_build_object('key', 'know_kits_stadium', 'group', 'Matchday ready', 'kind', 'tick',
      'label', 'I know my kits & stadium rules: licensed stadium, or Konami stadium with real name + home colours, no extras',
      'done', 'know_kits_stadium' = ANY (v_ticks))
  );

  RETURN v_items;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_owner_ready_items(text, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_current_season()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Owner panel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_season_ready_checklist()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint := public.gpsl_owner_ready_current_season();
  v_aug timestamptz;
  v_items jsonb;
BEGIN
  IF v_club IS NULL OR v_season IS NULL THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  SELECT cal.unlock_at INTO v_aug
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_season AND lower(btrim(cal.gpsl_month)) = 'august'
  LIMIT 1;

  IF v_aug IS NOT NULL AND now() >= v_aug THEN
    RETURN jsonb_build_object('visible', false, 'august_unlock_at', v_aug);
  END IF;

  v_items := public.gpsl_owner_ready_items(v_club, v_season);

  RETURN jsonb_build_object(
    'visible', true,
    'club_short_name', v_club,
    'season_id', v_season,
    'august_unlock_at', v_aug,
    'items', v_items
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_season_ready_checklist() TO authenticated;

-- ---------------------------------------------------------------------------
-- Tick / untick
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_ready_tick(
  p_item_key text,
  p_ticked boolean DEFAULT true,
  p_fixture_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  v_key text := lower(btrim(coalesce(p_item_key, '')));
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club'; END IF;
  IF NOT (v_key = ANY (public.gpsl_owner_ready_tick_keys(p_fixture_id IS NOT NULL))) THEN
    RAISE EXCEPTION 'Unknown checklist item';
  END IF;

  IF p_fixture_id IS NOT NULL THEN
    SELECT f.season_id INTO v_season
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)));
    IF NOT FOUND THEN RAISE EXCEPTION 'Not your fixture'; END IF;
  ELSE
    v_season := public.gpsl_owner_ready_current_season();
  END IF;

  IF coalesce(p_ticked, true) THEN
    INSERT INTO public.owner_ready_ticks (club_short_name, season_id, fixture_id, item_key, ticked_by)
    VALUES (v_club, v_season, p_fixture_id, v_key, auth.uid())
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.owner_ready_ticks t
    WHERE upper(t.club_short_name) = v_club
      AND coalesce(t.season_id, 0) = coalesce(v_season, 0)
      AND coalesce(t.fixture_id, 0) = coalesce(p_fixture_id, 0)
      AND t.item_key = v_key;
  END IF;
  RETURN true;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_ready_tick(text, boolean, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin summary (Club Checklist "Ready" column)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_owner_ready_summary()
RETURNS TABLE (club_short_name text, ready_done int, ready_total int, missing text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpsl_owner_ready_current_season();
  c record;
  v_items jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND NOT (to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL AND public.is_gpsl_admin_or_mod()) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR c IN
    SELECT cl."ShortName" AS short
    FROM public."Clubs" cl
    WHERE cl.owner_id IS NOT NULL AND cl."ShortName" <> 'FOREIGN'
  LOOP
    BEGIN
      v_items := public.gpsl_owner_ready_items(c.short, v_season);
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;
    club_short_name := c.short;
    SELECT
      count(*) FILTER (WHERE (i->>'done')::boolean)::int,
      count(*)::int,
      string_agg(i->>'label', '; ') FILTER (WHERE NOT (i->>'done')::boolean)
    INTO ready_done, ready_total, missing
    FROM jsonb_array_elements(v_items) i
    WHERE i->>'kind' <> 'recommended';
    RETURN NEXT;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_ready_summary() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: every owned club's readiness right now
SELECT * FROM public.admin_owner_ready_summary() ORDER BY ready_done, club_short_name;
