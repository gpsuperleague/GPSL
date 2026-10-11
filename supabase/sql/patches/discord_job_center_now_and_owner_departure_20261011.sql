-- =============================================================================
-- Discord: Job Center "post now" + owner departure news
--
-- 1) admin_discord_job_center_post_now() — posts the vacant clubs in this
--    season's active divisions (Super League / Championship A / B) to
--    #gpsl-job-center on demand (admin Discord page button). The daily
--    automatic post is unchanged.
-- 2) When an owner leaves a club (owner removed or replaced) → #gpsl-news
--    "👋 OWNER DEPARTS". If the club is now vacant and in a league this
--    season, it is also posted to #gpsl-job-center as available.
--    Same Season 1 pre-season quiet rule as the NEW OWNER post.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_division_label(p_division text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE lower(coalesce(p_division, ''))
    WHEN 'superleague' THEN 'Super League'
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE coalesce(nullif(p_division, ''), 'League')
  END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_job_center_post_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_count int := 0;
  v_lines text;
  v_qid bigint;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No current season');
  END IF;

  SELECT count(*)::int,
         string_agg(
           format('• **%s** (%s)',
                  coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
                  public.gpsl_discord_division_label(ccs.division)),
           E'\n'
           ORDER BY
             CASE lower(ccs.division)
               WHEN 'superleague' THEN 1
               WHEN 'championship_a' THEN 2
               WHEN 'championship_b' THEN 3
               ELSE 9
             END,
             c."Club"
         )
  INTO v_count, v_lines
  FROM public.competition_club_seasons ccs
  JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
  WHERE ccs.season_id = v_season_id
    AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
    AND c.owner_id IS NULL
    AND c."ShortName" IS DISTINCT FROM 'FOREIGN';

  IF coalesce(v_count, 0) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'posted', false, 'vacant', 0);
  END IF;

  v_qid := public.gpsl_discord_feed_enqueue_job_center(
    'job_center',
    format('🏚️ JOB CENTER — %s club(s) available', v_count),
    left(v_lines || E'\n\nInterested? Ask an admin in Discord to take one over.', 3800),
    10038562,
    'job_center_now:' || floor(extract(epoch FROM now()))::bigint::text,
    jsonb_build_object('kind', 'job_center', 'count', v_count, 'season_id', v_season_id, 'manual', true)
  );

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'posted', v_qid IS NOT NULL, 'vacant', v_count, 'queue_id', v_qid);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_job_center_post_now() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_discord_job_center_post_now() TO authenticated, service_role;

-- Owner leaves a club → news (+ job center if now vacant league club)
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_owner_depart()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_tag text;
  v_discord_id text;
  v_season_id bigint;
  v_division text;
BEGIN
  IF OLD.owner_id IS NULL OR OLD.owner_id IS NOT DISTINCT FROM NEW.owner_id THEN
    RETURN NEW;
  END IF;

  v_season_id := public.gpsl_discord_feed_current_season_id();
  IF public.gpsl_discord_feed_is_season1(v_season_id)
     AND public.gpsl_discord_feed_is_preseason() THEN
    RETURN NEW;
  END IF;

  v_club := coalesce(NEW."Club", public.gpsl_discord_feed_club_name(NEW."ShortName"));

  BEGIN
    SELECT nullif(btrim(r.owner_tag), ''), nullif(btrim(r.discord_user_id), '')
    INTO v_tag, v_discord_id
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = OLD.owner_id
    LIMIT 1;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    v_tag := NULL;
    v_discord_id := NULL;
  END;
  v_tag := ltrim(coalesce(v_tag, nullif(btrim(OLD.owner), ''), 'The owner'), '@');

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('👋 OWNER DEPARTS — %s', v_club),
    CASE WHEN NEW.owner_id IS NULL
      THEN format('%s has left %s. The club is now looking for a new owner.', v_tag, v_club)
      ELSE format('%s has left %s.', v_tag, v_club)
    END,
    10038562,
    'owner_depart:' || NEW."ShortName" || ':' || OLD.owner_id::text || ':'
      || floor(extract(epoch FROM now()))::bigint::text,
    jsonb_build_object(
      'kind', 'owner_depart',
      'club', NEW."ShortName",
      'owner_id', OLD.owner_id,
      'owner_tag', v_tag,
      'discord_user_id', v_discord_id,
      'channel', 'news'
    )
  );

  IF NEW.owner_id IS NULL AND v_season_id IS NOT NULL THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = NEW."ShortName"
      AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
    LIMIT 1;

    IF v_division IS NOT NULL THEN
      PERFORM public.gpsl_discord_feed_enqueue_job_center(
        'job_center',
        format('🏚️ NOW AVAILABLE — %s', v_club),
        format('%s (%s) no longer has an owner. Interested? Ask an admin in Discord.',
               v_club, public.gpsl_discord_division_label(v_division)),
        10038562,
        'job_center_vacant:' || NEW."ShortName" || ':' || floor(extract(epoch FROM now()))::bigint::text,
        jsonb_build_object('kind', 'club_vacant', 'club', NEW."ShortName", 'division', v_division)
      );
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'owner departure Discord post failed for %: %', NEW."ShortName", SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_owner_depart ON public."Clubs";
CREATE TRIGGER trg_gpsl_discord_feed_owner_depart
  AFTER UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_owner_depart();

NOTIFY pgrst, 'reload schema';

-- Report: what "Post Job Center now" would list
SELECT coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club,
       public.gpsl_discord_division_label(ccs.division) AS division
FROM public.competition_club_seasons ccs
JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
WHERE ccs.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
  AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
  AND c.owner_id IS NULL
ORDER BY ccs.division, c."Club";
