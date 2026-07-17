-- =============================================================================
-- Discord NEW OWNER: use Discord display name, not "@New owner"
--
-- 1) Adds optional 3-arg admin_assign_club_owner(..., p_owner_tag) that saves
--    the tag BEFORE linking (so the Discord trigger can read it).
-- 2) Does NOT replace the existing 2-arg assign (keeps finances/welcome/etc.).
-- 3) Hardens Discord trigger fallback when tag is still missing.
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- Thin wrapper: set Discord tag, then call existing 2-arg assign
CREATE OR REPLACE FUNCTION public.admin_assign_club_owner(
  p_owner_email text,
  p_club_short_name text,
  p_owner_tag text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_user_id uuid;
  v_tag text := nullif(btrim(coalesce(p_owner_tag, '')), '');
  v_result jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_tag IS NOT NULL THEN
    IF length(v_tag) > 64 THEN
      RAISE EXCEPTION 'Owner tag is too long (max 64 characters)';
    END IF;

    SELECT u.id INTO v_user_id
    FROM auth.users u
    WHERE lower(u.email) = v_email
    LIMIT 1;

    IF v_user_id IS NULL THEN
      RAISE EXCEPTION 'No auth user with email %', p_owner_email;
    END IF;

    -- Registry first (Discord trigger reads this on owner_id change)
    INSERT INTO public.gpsl_owner_registry (
      owner_id, status, owner_tag, status_changed_at
    )
    VALUES (v_user_id, 'on_break', v_tag, now())
    ON CONFLICT (owner_id) DO UPDATE
    SET owner_tag = excluded.owner_tag,
        status_changed_at = now();

    -- If already on a club, keep Clubs.owner in sync
    UPDATE public."Clubs"
    SET owner = v_tag
    WHERE owner_id = v_user_id;
  END IF;

  -- Existing 2-arg implementation (finances, welcome, waiting list, tenure, …)
  v_result := public.admin_assign_club_owner(p_owner_email, p_club_short_name);

  IF v_tag IS NOT NULL THEN
    v_result := v_result || jsonb_build_object('owner_tag', v_tag);
  END IF;

  RETURN v_result;
END;
$function$;

-- Prefer registry / Clubs.owner; avoid literal "New owner"
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_owner_assign()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_tag text;
  v_mention text;
  v_season_id bigint;
BEGIN
  IF NEW.owner_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.owner_id IS NOT DISTINCT FROM NEW.owner_id THEN
    RETURN NEW;
  END IF;

  v_season_id := public.gpsl_discord_feed_current_season_id();
  IF public.gpsl_discord_feed_is_season1(v_season_id)
     AND public.gpsl_discord_feed_is_preseason() THEN
    RETURN NEW;
  END IF;

  v_club := coalesce(NEW."Club", public.gpsl_discord_feed_club_name(NEW."ShortName"));

  BEGIN
    SELECT nullif(btrim(r.owner_tag), '') INTO v_tag
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = NEW.owner_id
    LIMIT 1;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    v_tag := null;
  END;

  v_tag := coalesce(
    v_tag,
    nullif(btrim(NEW.owner), ''),
    nullif(btrim(OLD.owner), '')
  );

  -- Treat placeholders / shortnames as missing
  IF v_tag IS NULL
     OR lower(v_tag) IN ('new owner', 'owner', 'unknown')
     OR upper(v_tag) = upper(NEW."ShortName") THEN
    v_tag := '(set Discord tag)';
  END IF;

  v_mention := '@' || ltrim(v_tag, '@');

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('🏟️ NEW OWNER — %s', v_club),
    format('%s have appointed %s.', v_club, v_mention),
    15844367,
    'owner_appoint:' || NEW."ShortName" || ':' || NEW.owner_id::text,
    jsonb_build_object(
      'club', NEW."ShortName",
      'owner_id', NEW.owner_id,
      'owner_tag', v_tag,
      'mention', v_mention
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_owner_assign ON public."Clubs";
CREATE TRIGGER trg_gpsl_discord_feed_owner_assign
  AFTER UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_owner_assign();

GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
