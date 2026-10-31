-- Mid-season handpick: temp GPDB tags (wishlist basket)
-- Soft hold only — does NOT set Players.Contracted_Team.
-- Safe re-run.

CREATE TABLE IF NOT EXISTS public.club_handpick_basket (
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  player_id text NOT NULL,
  added_at timestamptz NOT NULL DEFAULT now(),
  added_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  PRIMARY KEY (club_short_name, player_id)
);

CREATE INDEX IF NOT EXISTS club_handpick_basket_player_idx
  ON public.club_handpick_basket (player_id);

CREATE INDEX IF NOT EXISTS club_handpick_basket_club_added_idx
  ON public.club_handpick_basket (club_short_name, added_at DESC);

ALTER TABLE public.club_handpick_basket ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_handpick_basket_admin_all ON public.club_handpick_basket;
CREATE POLICY club_handpick_basket_admin_all
  ON public.club_handpick_basket
  FOR ALL
  TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS club_handpick_basket_owner_select ON public.club_handpick_basket;
CREATE POLICY club_handpick_basket_owner_select
  ON public.club_handpick_basket
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE c."ShortName" = club_handpick_basket.club_short_name
        AND c.owner_id = auth.uid()
    )
  );

COMMENT ON TABLE public.club_handpick_basket IS
  'Temp mid-season handpick wishlist tags (GPDB). Not a contract — cleared when handpick intake toggles.';

-- Clear basket whenever handpick_intake flips on/off (fresh start / end)
CREATE OR REPLACE FUNCTION public.trg_clubs_handpick_basket_clear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.handpick_intake IS DISTINCT FROM OLD.handpick_intake THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = NEW."ShortName";
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_handpick_basket_clear ON public."Clubs";
CREATE TRIGGER clubs_handpick_basket_clear
  AFTER UPDATE OF handpick_intake ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_handpick_basket_clear();

CREATE OR REPLACE FUNCTION public.handpick_basket_list(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club', NULL,
      'handpick_intake', false,
      'player_ids', '[]'::jsonb,
      'players', '[]'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'handpick_intake', EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE upper(c."ShortName") = v_club
        AND coalesce(c.handpick_intake, false)
    ),
    'player_ids', coalesce((
      SELECT jsonb_agg(b.player_id ORDER BY b.added_at, b.player_id)
      FROM public.club_handpick_basket b
      WHERE b.club_short_name = v_club
    ), '[]'::jsonb),
    'players', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.added_at, r.player_name)
      FROM (
        SELECT
          b.player_id,
          b.added_at,
          p."Name" AS player_name,
          p."Position" AS position,
          p."Rating" AS rating,
          p."Nation" AS nation,
          coalesce(
            nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          ) AS market_value,
          nullif(btrim(p."Contracted_Team"::text), '') AS contracted_team
        FROM public.club_handpick_basket b
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = b.player_id
        WHERE b.club_short_name = v_club
      ) r
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_basket_list(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_basket_list(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.handpick_basket_toggle(
  p_player_id text,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_handpick boolean := false;
  v_exists boolean := false;
  v_team text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT v_handpick THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_in_handpick',
      'detail', 'Handpick intake is not open for this club.'
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  -- Untag always allowed
  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_club AND player_id = v_pid;
    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'player_id', v_pid
    );
  END IF;

  SELECT nullif(btrim(p."Contracted_Team"::text), '') INTO v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'player_not_found');
  END IF;

  IF v_team IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_free_agent',
      'detail', 'Only free agents can be handpick-tagged.'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
      AND coalesce(p.pesdb_unavailable, false)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'legacy_card');
  END IF;

  IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
     AND public.gpdb_player_is_season_excluded(v_pid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'season_excluded');
  END IF;

  INSERT INTO public.club_handpick_basket (club_short_name, player_id, added_by)
  VALUES (v_club, v_pid, auth.uid())
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', true,
    'club', v_club,
    'player_id', v_pid
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_basket_toggle(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_basket_toggle(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.handpick_basket_clear(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_n int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  DELETE FROM public.club_handpick_basket
  WHERE club_short_name = v_club;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'club', v_club, 'cleared', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_basket_clear(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_basket_clear(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.handpick_basket_set(
  p_player_id text,
  p_tagged boolean,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_exists boolean := false;
  v_res jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  IF coalesce(p_tagged, false) THEN
    IF v_exists THEN
      RETURN jsonb_build_object(
        'ok', true,
        'tagged', true,
        'club', v_club,
        'player_id', v_pid
      );
    END IF;
    RETURN public.handpick_basket_toggle(v_pid, v_club);
  END IF;

  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_club AND player_id = v_pid;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', false,
    'club', v_club,
    'player_id', v_pid
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_basket_set(text, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_basket_set(text, boolean, text)
  TO authenticated;

-- Drop approved players from basket after successful non-dry-run approve
CREATE OR REPLACE FUNCTION public.admin_handpick_approve_submission(
  p_submission_id bigint,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_row public.club_handpick_submissions%ROWTYPE;
  v_handpick boolean;
  v_sign jsonb;
  v_mgr jsonb;
  v_fee numeric;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row
  FROM public.club_handpick_submissions
  WHERE id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_row.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_row.status);
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE c."ShortName" = v_row.club_short_name;

  IF NOT coalesce(v_handpick, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_in_handpick');
  END IF;

  IF coalesce(array_length(v_row.player_ids, 1), 0) > 0 THEN
    IF to_regprocedure('public.admin_sign_free_agents_at_mv(text,text[],boolean)') IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sign_rpc_missing');
    END IF;
    v_sign := public.admin_sign_free_agents_at_mv(
      v_row.club_short_name,
      v_row.player_ids,
      coalesce(p_dry_run, true)
    );
    IF NOT coalesce((v_sign->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'sign_failed',
        'sign_result', v_sign
      );
    END IF;
  ELSE
    v_sign := jsonb_build_object('ok', true, 'signed_count', 0, 'skipped_count', 0);
  END IF;

  IF v_row.manager_id IS NOT NULL THEN
    IF coalesce(p_dry_run, true) THEN
      SELECT coalesce(m.market_value, 0)::numeric INTO v_fee
      FROM public."Managers" m WHERE m.id = v_row.manager_id;
      v_mgr := jsonb_build_object(
        'ok', true,
        'dry_run', true,
        'manager_id', v_row.manager_id,
        'est_fee', coalesce(v_fee, 0)
      );
    ELSE
      BEGIN
        v_mgr := public.manager_assign_to_club(
          v_row.manager_id,
          v_row.club_short_name,
          2::smallint,
          NULL::numeric,
          true,
          jsonb_build_object('source', 'handpick_approve', 'submission_id', p_submission_id)
        );
      EXCEPTION WHEN OTHERS THEN
        v_mgr := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
  END IF;

  IF NOT coalesce(p_dry_run, true) THEN
    UPDATE public.club_handpick_submissions
    SET status = 'approved',
        reviewed_at = now(),
        reviewed_by = auth.uid(),
        sign_result = jsonb_build_object('players', v_sign, 'manager', v_mgr)
    WHERE id = p_submission_id;

    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_row.club_short_name
      AND (
        coalesce(array_length(v_row.player_ids, 1), 0) = 0
        OR player_id = ANY (v_row.player_ids)
      );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', coalesce(p_dry_run, true),
    'submission_id', p_submission_id,
    'club', v_row.club_short_name,
    'players', v_sign,
    'manager', v_mgr,
    'status', CASE WHEN coalesce(p_dry_run, true) THEN 'pending' ELSE 'approved' END
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regclass('public.club_handpick_basket') IS NOT NULL AS basket_table,
  to_regprocedure('public.handpick_basket_toggle(text,text)') IS NOT NULL AS toggle_rpc,
  to_regprocedure('public.handpick_basket_list(text)') IS NOT NULL AS list_rpc;
