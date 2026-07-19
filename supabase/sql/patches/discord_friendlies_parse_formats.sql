-- =============================================================================
-- Friendlies scoreline: accept both common formats + en/em dashes
--
-- A) CLUB score - score CLUB   e.g. JUB 2 - 2 BEN  (original)
-- B) CLUB score - CLUB score   e.g. ROS 2 - JUB 3  (natural Discord style)
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Then redeploy: supabase functions deploy discord-friendlies-ingest
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_parse_scoreline(p_content text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_raw text := btrim(coalesce(p_content, ''));
  v_club_l text;
  v_club_r text;
  v_score_l int;
  v_score_r int;
  v_m text[];
BEGIN
  -- Normalise fancy dashes / minus signs Discord often inserts
  v_raw := regexp_replace(v_raw, E'[\\u2013\\u2014\\u2212\\u2010\\u2011]', '-', 'g');
  v_raw := regexp_replace(v_raw, E'[\\u200B-\\u200D\\uFEFF]', '', 'g');
  v_raw := btrim(v_raw);

  -- A) CLUB score - score CLUB  (JUB 2 - 2 BEN)
  v_m := regexp_match(
    v_raw,
    '^([A-Za-z0-9]{2,8})\s+(\d{1,2})\s*-\s*(\d{1,2})\s+([A-Za-z0-9]{2,8})$'
  );
  IF v_m IS NOT NULL THEN
    v_club_l := upper(v_m[1]);
    v_score_l := v_m[2]::int;
    v_score_r := v_m[3]::int;
    v_club_r := upper(v_m[4]);
  ELSE
    -- B) CLUB score - CLUB score  (ROS 2 - JUB 3)
    v_m := regexp_match(
      v_raw,
      '^([A-Za-z0-9]{2,8})\s+(\d{1,2})\s*-\s*([A-Za-z0-9]{2,8})\s+(\d{1,2})$'
    );
    IF v_m IS NULL THEN
      RETURN NULL;
    END IF;
    v_club_l := upper(v_m[1]);
    v_score_l := v_m[2]::int;
    v_club_r := upper(v_m[3]);
    v_score_r := v_m[4]::int;
  END IF;

  IF v_club_l IS NULL OR v_club_r IS NULL OR v_club_l = v_club_r THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'club_left', v_club_l,
    'score_left', v_score_l,
    'club_right', v_club_r,
    'score_right', v_score_r
  );
END;
$function$;

COMMENT ON FUNCTION public.gpsl_friendlies_parse_scoreline(text) IS
  'Parse friendlies: "JUB 2 - 2 BEN" or "ROS 2 - JUB 3" (en-dashes ok).';
