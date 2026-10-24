-- =============================================================================
-- Allow MEGA share links for match videos (alongside YouTube + Discord CDN).
-- Hosts: mega.nz, mega.co.nz (legacy). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_video_url_allowed(p_url text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := btrim(coalesce(p_url, ''));
  v_host text;
BEGIN
  IF v = '' OR length(v) > 2000 THEN
    RETURN false;
  END IF;
  IF v !~* '^https://' THEN
    RETURN false;
  END IF;
  IF v ~ '[[:space:]]' OR position('@' in v) > 0 THEN
    RETURN false;
  END IF;

  v_host := lower(substring(v from '^https://([^/?:#]+)'));
  IF v_host IS NULL OR v_host = '' THEN
    RETURN false;
  END IF;
  IF left(v_host, 4) = 'www.' THEN
    v_host := substring(v_host from 5);
  END IF;

  IF v_host IN (
    'youtube.com',
    'm.youtube.com',
    'youtu.be',
    'youtube-nocookie.com'
  ) THEN
    RETURN true;
  END IF;

  IF v_host IN (
    'mega.nz',
    'mega.co.nz'
  ) THEN
    RETURN true;
  END IF;

  IF v_host IN (
    'cdn.discordapp.com',
    'media.discordapp.net'
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

COMMENT ON FUNCTION public.match_video_url_allowed(text) IS
  'Match videos: https YouTube, MEGA (mega.nz / mega.co.nz), or Discord CDN.';

-- Refresh rejection copy inside ingest without rewriting the whole function body.
DO $$
DECLARE
  def text;
  old_msg text :=
    'URL not allowed — use an https YouTube link (youtu.be / youtube.com) or Discord video attachment';
  new_msg text :=
    'URL not allowed — use https YouTube, MEGA (mega.nz), or a Discord video attachment';
BEGIN
  SELECT pg_get_functiondef(p.oid)
  INTO def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'match_video_ingest_attachment'
  LIMIT 1;

  IF def IS NULL THEN
    RAISE NOTICE 'match_video_ingest_attachment not found — skipped message update';
    RETURN;
  END IF;

  IF position(old_msg in def) = 0 THEN
    -- Already updated or older wording; try shorter legacy string.
    old_msg := 'URL not allowed — use https YouTube (youtu.be / youtube.com) or Discord CDN';
  END IF;

  IF position(old_msg in def) > 0 THEN
    def := replace(def, old_msg, new_msg);
    EXECUTE def;
  ELSE
    RAISE NOTICE 'ingest URL-not-allowed message already current or unknown wording';
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';

SELECT
  public.match_video_url_allowed('https://mega.nz/file/AbCdEfGh#key') AS mega_ok,
  public.match_video_url_allowed('https://mega.co.nz/#!abc!def') AS mega_legacy_ok,
  public.match_video_url_allowed('https://youtu.be/xxxxxxxxxxx') AS yt_ok,
  public.match_video_url_allowed('https://drive.google.com/file/d/x') AS drive_blocked;
