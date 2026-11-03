-- =============================================================================
-- Private "want to sell" marks on own players + who is scouting your squad.
--
-- club_player_sale_marks: owner-only soft tags (not a listing).
-- club_my_players_scouting_interest: SECURITY DEFINER — other clubs' shortlist
-- hits on YOUR contracted players only (club + owner tag for badge tooltips).
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_player_sale_marks (
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON UPDATE CASCADE ON DELETE CASCADE,
  player_id text NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT club_player_sale_marks_pk PRIMARY KEY (club_short_name, player_id),
  CONSTRAINT club_player_sale_marks_note_len_chk
    CHECK (note IS NULL OR char_length(note) <= 280)
);

CREATE INDEX IF NOT EXISTS club_player_sale_marks_player_idx
  ON public.club_player_sale_marks (player_id);

COMMENT ON TABLE public.club_player_sale_marks IS
  'Owner-private want-to-sell marks on contracted players (not a transfer listing).';

ALTER TABLE public.club_player_sale_marks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_player_sale_marks_owner_all ON public.club_player_sale_marks;
CREATE POLICY club_player_sale_marks_owner_all
  ON public.club_player_sale_marks
  FOR ALL
  TO authenticated
  USING (
    club_short_name = public.my_club_shortname()
  )
  WITH CHECK (
    club_short_name = public.my_club_shortname()
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_player_sale_marks TO authenticated;

-- ---------------------------------------------------------------------------
-- Set / clear mark
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_player_sale_mark_set(
  p_player_id text,
  p_want_to_sell boolean DEFAULT true,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_pid text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_team text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club';
  END IF;
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'Player required';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    RAISE EXCEPTION 'Note too long (max 280)';
  END IF;

  SELECT nullif(btrim(p."Contracted_Team"), '') INTO v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  LIMIT 1;

  IF v_team IS NULL OR upper(v_team) IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  IF NOT coalesce(p_want_to_sell, true) THEN
    DELETE FROM public.club_player_sale_marks
    WHERE club_short_name = v_club
      AND player_id = v_pid;
    RETURN jsonb_build_object('ok', true, 'want_to_sell', false, 'player_id', v_pid);
  END IF;

  INSERT INTO public.club_player_sale_marks AS m (
    club_short_name, player_id, note, updated_at
  ) VALUES (
    v_club, v_pid, v_note, now()
  )
  ON CONFLICT (club_short_name, player_id) DO UPDATE
  SET note = EXCLUDED.note,
      updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'want_to_sell', true,
    'player_id', v_pid,
    'note', v_note
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_player_sale_mark_set(text, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_player_sale_mark_set(text, boolean, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- List marks for my club (with live MV / name for Transfer Centre)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_player_sale_marks_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_rows jsonb;
  v_total numeric := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club', null, 'marks', '[]'::jsonb, 'total_market_value', 0);
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.market_value DESC NULLS LAST, x.player_name), '[]'::jsonb),
         coalesce(sum(x.market_value), 0)
  INTO v_rows, v_total
  FROM (
    SELECT
      m.player_id,
      m.note,
      m.updated_at,
      p."Name" AS player_name,
      p."Position" AS position,
      nullif(btrim(p."Rating"::text), '') AS overall_rating,
      coalesce(nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.\-]', '', 'g'), '')::numeric, 0) AS market_value,
      EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.player_id::text = m.player_id
          AND l.seller_club_id = v_club
          AND l.status IN ('Active', 'Pending Window', 'Review', 'Seller Review')
      ) AS is_listed
    FROM public.club_player_sale_marks m
    JOIN public."Players" p
      ON p."Konami_ID"::text = m.player_id
     AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_club
    WHERE m.club_short_name = v_club
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'marks', coalesce(v_rows, '[]'::jsonb),
    'total_market_value', coalesce(v_total, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_player_sale_marks_list()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_player_sale_marks_list()
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Who is scouting MY contracted players (badge source for Squad / TC)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_my_players_scouting_interest(
  p_player_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club', null, 'by_player', '{}'::jsonb);
  END IF;

  SELECT coalesce(jsonb_object_agg(z.player_id, z.clubs), '{}'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      y.player_id,
      jsonb_agg(
        jsonb_build_object(
          'club_short_name', y.club_short_name,
          'club_name', y.club_name,
          'owner_tag', y.owner_tag,
          'tier', y.tier,
          'is_active_target', y.is_active_target
        )
        ORDER BY y.club_name
      ) AS clubs
    FROM (
      SELECT DISTINCT ON (t.player_id, c."ShortName")
        t.player_id::text AS player_id,
        c."ShortName" AS club_short_name,
        coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
        coalesce(
          nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          '—'
        ) AS owner_tag,
        t.tier,
        coalesce(t.is_active_target, false) AS is_active_target
      FROM public.owner_scouting_targets t
      JOIN public."Clubs" c
        ON c.owner_id = t.owner_id
       AND c."ShortName" IS DISTINCT FROM v_club
      JOIN public."Players" p
        ON p."Konami_ID"::text = t.player_id::text
       AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_club
      WHERE (
        p_player_ids IS NULL
        OR cardinality(p_player_ids) = 0
        OR t.player_id::text = ANY (p_player_ids)
      )
      ORDER BY t.player_id, c."ShortName", coalesce(t.is_active_target, false) DESC, t.tier ASC
    ) y
    GROUP BY y.player_id
  ) z;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'by_player', coalesce(v_rows, '{}'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_my_players_scouting_interest(text[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_my_players_scouting_interest(text[])
  TO authenticated;

NOTIFY pgrst, 'reload schema';
