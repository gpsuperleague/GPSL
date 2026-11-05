-- Vacant club assignment reserve
-- Admin can mark a vacant club "reserved" so claim / link / change-club
-- cannot assign an owner until the reserve is cleared.

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS assignment_reserved boolean NOT NULL DEFAULT false;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS assignment_reserved_at timestamptz;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS assignment_reserved_note text;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS assignment_reserved_by uuid;

COMMENT ON COLUMN public."Clubs".assignment_reserved IS
  'When true, vacant club cannot receive an owner until admin clears the reserve.';

-- ---------------------------------------------------------------------------
-- Hard gate: any path that sets owner_id on a reserved club fails
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clubs_block_assign_when_reserved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.owner_id IS NOT NULL
     AND NEW.owner_id IS DISTINCT FROM OLD.owner_id
     AND coalesce(NEW.assignment_reserved, false) THEN
    RAISE EXCEPTION
      'Club % is reserved — clear the reserve in Admin → Club assignment → Reserve vacant club before assigning an owner',
      NEW."ShortName";
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_block_assign_when_reserved_trg ON public."Clubs";
CREATE TRIGGER clubs_block_assign_when_reserved_trg
  BEFORE UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.clubs_block_assign_when_reserved();

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_club_vacant_for_reserve_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'clubs', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'short_name', q.short_name,
          'club_name', q.club_name,
          'division', q.division,
          'division_label', q.division_label,
          'assignment_reserved', q.assignment_reserved
        )
        ORDER BY q.div_rank, q.club_name
      )
      FROM (
        SELECT
          c."ShortName" AS short_name,
          coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
          ccs.division,
          CASE
            WHEN to_regprocedure('public.gpsl_discord_division_label(text)') IS NOT NULL
              THEN public.gpsl_discord_division_label(ccs.division)
            ELSE coalesce(ccs.division, 'Not in a division')
          END AS division_label,
          coalesce(c.assignment_reserved, false) AS assignment_reserved,
          CASE lower(coalesce(ccs.division, ''))
            WHEN 'superleague' THEN 1
            WHEN 'championship_a' THEN 2
            WHEN 'championship_b' THEN 3
            WHEN '' THEN 5
            ELSE 4
          END AS div_rank
        FROM public."Clubs" c
        LEFT JOIN public.competition_club_seasons ccs
          ON ccs.club_short_name = c."ShortName"
         AND ccs.season_id = v_season_id
        WHERE c.owner_id IS NULL
          AND upper(c."ShortName") <> 'FOREIGN'
          AND coalesce(c.is_archived, false) = false
          AND coalesce(c.assignment_reserved, false) = false
      ) q
    ), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_assignment_reserved_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'clubs', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'short_name', c."ShortName",
          'club_name', coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
          'reserved_at', c.assignment_reserved_at,
          'reserved_note', c.assignment_reserved_note,
          'reserved_by', c.assignment_reserved_by
        )
        ORDER BY c."Club"
      )
      FROM public."Clubs" c
      WHERE coalesce(c.assignment_reserved, false) = true
        AND upper(c."ShortName") <> 'FOREIGN'
    ), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_assignment_reserve(
  p_club_short_name text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(coalesce(p_club_short_name, '')));
  v_club text;
  v_name text;
  v_owner uuid;
  v_arch boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_short = '' OR v_short = 'FOREIGN' THEN
    RAISE EXCEPTION 'Pick a club';
  END IF;

  SELECT c."ShortName", c."Club", c.owner_id, coalesce(c.is_archived, false)
  INTO v_club, v_name, v_owner, v_arch
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_short
  FOR UPDATE;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club not found';
  END IF;
  IF v_arch THEN
    RAISE EXCEPTION 'Archived clubs cannot be reserved';
  END IF;
  IF v_owner IS NOT NULL THEN
    RAISE EXCEPTION 'Club has an owner — remove the owner first, then reserve';
  END IF;

  UPDATE public."Clubs"
  SET assignment_reserved = true,
      assignment_reserved_at = now(),
      assignment_reserved_note = nullif(btrim(p_note), ''),
      assignment_reserved_by = auth.uid()
  WHERE "ShortName" = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'short_name', v_club,
    'club_name', v_name,
    'reserved', true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_assignment_clear_reserve(
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(coalesce(p_club_short_name, '')));
  v_club text;
  v_name text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT c."ShortName", c."Club"
  INTO v_club, v_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_short
  FOR UPDATE;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  UPDATE public."Clubs"
  SET assignment_reserved = false,
      assignment_reserved_at = NULL,
      assignment_reserved_note = NULL,
      assignment_reserved_by = NULL
  WHERE "ShortName" = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'short_name', v_club,
    'club_name', v_name,
    'reserved', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_club_vacant_for_reserve_list() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_club_assignment_reserved_list() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_club_assignment_reserve(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_club_assignment_clear_reserve(text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_club_vacant_for_reserve_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_assignment_reserved_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_assignment_reserve(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_assignment_clear_reserve(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Hide reserved clubs from staff assign + mid-season claim pickers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_vacant_clubs_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_season_label text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_only');
  END IF;

  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'clubs', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'short_name', q.short_name,
          'club_name', q.club_name,
          'division', q.division,
          'division_label', q.division_label
        )
        ORDER BY q.div_rank, q.club_name
      )
      FROM (
        SELECT
          c."ShortName" AS short_name,
          coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
          ccs.division,
          public.gpsl_discord_division_label(ccs.division) AS division_label,
          CASE lower(ccs.division)
            WHEN 'superleague' THEN 1
            WHEN 'championship_a' THEN 2
            WHEN 'championship_b' THEN 3
            ELSE 4
          END AS div_rank
        FROM public.competition_club_seasons ccs
        JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
        WHERE ccs.season_id = v_season_id
          AND c.owner_id IS NULL
          AND upper(c."ShortName") <> 'FOREIGN'
          AND coalesce(c.is_archived, false) = false
          AND coalesce(c.assignment_reserved, false) = false

        UNION ALL

        SELECT
          c."ShortName" AS short_name,
          coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
          NULL::text AS division,
          'Not in a division'::text AS division_label,
          5 AS div_rank
        FROM public."Clubs" c
        WHERE c.owner_id IS NULL
          AND upper(c."ShortName") <> 'FOREIGN'
          AND coalesce(c.is_archived, false) = false
          AND coalesce(c.assignment_reserved, false) = false
          AND NOT EXISTS (
            SELECT 1
            FROM public.competition_club_seasons ccs
            WHERE ccs.season_id = v_season_id
              AND ccs.club_short_name = c."ShortName"
          )
      ) q
    ), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.waiting_list_vacant_clubs_for_claim()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_mode text := public.gpsl_owner_intake_mode();
  v_status text;
  v_has_club boolean := false;
  v_season_id bigint;
  v_season_label text;
  v_can_claim boolean := false;
  v_reason text := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'mode', v_mode);
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c.owner_id = v_uid
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
  ) INTO v_has_club;

  IF v_has_club THEN
    v_reason := 'already_has_club';
  ELSIF v_status IS NULL OR v_status = 'archived' THEN
    v_reason := 'not_on_registry';
  ELSIF v_status = 'awaiting_club_auction' THEN
    v_reason := 'auction_invite_active';
  ELSIF NOT public.waiting_list_on_list_status(v_status) THEN
    v_reason := 'not_on_waiting_list';
  ELSIF v_mode IS DISTINCT FROM 'mid_season' THEN
    v_reason := 'pre_season_use_auction';
  ELSE
    v_can_claim := true;
  END IF;

  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'mode', v_mode,
    'can_claim', v_can_claim,
    'reason', v_reason,
    'registry_status', v_status,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'clubs', CASE
      WHEN v_mode IS DISTINCT FROM 'mid_season' OR v_season_id IS NULL THEN '[]'::jsonb
      ELSE coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'short_name', q.short_name,
            'club_name', q.club_name,
            'division', q.division,
            'division_label', q.division_label
          )
          ORDER BY q.div_rank, q.club_name
        )
        FROM (
          SELECT
            c."ShortName" AS short_name,
            coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
            ccs.division,
            CASE
              WHEN to_regprocedure('public.gpsl_discord_division_label(text)') IS NOT NULL
                THEN public.gpsl_discord_division_label(ccs.division)
              ELSE ccs.division
            END AS division_label,
            CASE lower(ccs.division)
              WHEN 'superleague' THEN 1
              WHEN 'championship_a' THEN 2
              WHEN 'championship_b' THEN 3
              ELSE 4
            END AS div_rank
          FROM public.competition_club_seasons ccs
          JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
          WHERE ccs.season_id = v_season_id
            AND c.owner_id IS NULL
            AND upper(c."ShortName") <> 'FOREIGN'
            AND coalesce(c.is_archived, false) = false
            AND coalesce(c.assignment_reserved, false) = false
            AND nullif(btrim(ccs.division), '') IS NOT NULL
            AND lower(btrim(ccs.division)) IN (
              'superleague', 'championship_a', 'championship_b'
            )
        ) q
      ), '[]'::jsonb)
    END
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
