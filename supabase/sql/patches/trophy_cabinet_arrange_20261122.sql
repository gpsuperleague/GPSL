-- Display layout for a club's trophy cabinet.
-- Does not change archived honours. Only the club owner can save places.

CREATE TABLE IF NOT EXISTS public.competition_trophy_cabinet_place (
  club_short_name text NOT NULL,
  honour_key text NOT NULL,
  shelf smallint,
  slot smallint,
  stored boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_short_name, honour_key),
  CONSTRAINT competition_trophy_cabinet_place_spot CHECK (
    (stored AND shelf IS NULL AND slot IS NULL)
    OR (
      NOT stored
      AND shelf BETWEEN 0 AND 2
      AND slot BETWEEN 0 AND 4
    )
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS competition_trophy_cabinet_place_spot_uidx
  ON public.competition_trophy_cabinet_place (club_short_name, shelf, slot)
  WHERE NOT stored;

ALTER TABLE public.competition_trophy_cabinet_place ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.competition_trophy_cabinet_place FROM PUBLIC;
REVOKE ALL ON TABLE public.competition_trophy_cabinet_place FROM anon;
REVOKE ALL ON TABLE public.competition_trophy_cabinet_place FROM authenticated;

CREATE OR REPLACE FUNCTION public.competition_trophy_honour_key(
  p_type text,
  p_season text,
  p_division text,
  p_cup text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $gpsl$
  SELECT coalesce(p_type, '') || '|' || coalesce(p_season, '') || '|' ||
    CASE
      WHEN p_type = 'league_champion' THEN coalesce(p_division, '')
      ELSE coalesce(p_cup, '')
    END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_trophy_cabinet_get(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_places jsonb;
  v_owner boolean := false;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('can_arrange', false, 'places', '[]'::jsonb);
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND c.owner_id = auth.uid()
  )
  INTO v_owner;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'honour_key', p.honour_key,
      'shelf', p.shelf,
      'slot', p.slot,
      'stored', p.stored
    )
    ORDER BY p.stored, p.shelf, p.slot, p.honour_key
  ), '[]'::jsonb)
  INTO v_places
  FROM public.competition_trophy_cabinet_place p
  WHERE p.club_short_name = v_club;

  RETURN jsonb_build_object(
    'can_arrange', v_owner,
    'places', v_places
  );
END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_trophy_cabinet_save(
  p_club_short_name text,
  p_places jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_row record;
  v_stored boolean;
  v_shelf smallint;
  v_slot smallint;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
  END IF;

  IF v_club = '' OR NOT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND c.owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
  END IF;

  IF p_places IS NULL OR jsonb_typeof(p_places) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_places');
  END IF;

  DROP TABLE IF EXISTS tmp_cabinet_places;
  CREATE TEMP TABLE tmp_cabinet_places (
    honour_key text PRIMARY KEY,
    shelf smallint,
    slot smallint,
    stored boolean NOT NULL
  ) ON COMMIT DROP;

  FOR v_row IN
    SELECT *
    FROM jsonb_to_recordset(p_places) AS x(
      honour_key text,
      shelf smallint,
      slot smallint,
      stored boolean
    )
  LOOP
    IF v_row.honour_key IS NULL OR btrim(v_row.honour_key) = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'bad_key');
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_club_honours_public h
      WHERE h.club_short_name = v_club
        AND public.competition_trophy_honour_key(
          h.honour_type, h.season_label, h.division, h.cup_code
        ) = v_row.honour_key
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unknown_honour', 'honour_key', v_row.honour_key);
    END IF;

    v_stored := coalesce(v_row.stored, false);
    v_shelf := v_row.shelf;
    v_slot := v_row.slot;

    IF v_stored THEN
      v_shelf := NULL;
      v_slot := NULL;
    ELSIF v_shelf IS NULL OR v_slot IS NULL
      OR v_shelf < 0 OR v_shelf > 2
      OR v_slot < 0 OR v_slot > 4 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'bad_spot', 'honour_key', v_row.honour_key);
    END IF;

    IF EXISTS (
      SELECT 1 FROM tmp_cabinet_places t WHERE t.honour_key = v_row.honour_key
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'duplicate_key');
    END IF;

    INSERT INTO tmp_cabinet_places (honour_key, shelf, slot, stored)
    VALUES (v_row.honour_key, v_shelf, v_slot, v_stored);
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM tmp_cabinet_places
    WHERE NOT stored
    GROUP BY shelf, slot
    HAVING count(*) > 1
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'duplicate_spot');
  END IF;

  DELETE FROM public.competition_trophy_cabinet_place
  WHERE club_short_name = v_club;

  INSERT INTO public.competition_trophy_cabinet_place (
    club_short_name, honour_key, shelf, slot, stored, updated_at
  )
  SELECT v_club, t.honour_key, t.shelf, t.slot, t.stored, now()
  FROM tmp_cabinet_places t;

  RETURN public.competition_trophy_cabinet_get(v_club) || jsonb_build_object('ok', true);
END;
$gpsl$;

GRANT EXECUTE ON FUNCTION public.competition_trophy_honour_key(text, text, text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_trophy_cabinet_get(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_trophy_cabinet_save(text, jsonb) TO authenticated;

SELECT jsonb_build_object(
  'get', public.competition_trophy_cabinet_get('JUB'),
  'save_as_cli', public.competition_trophy_cabinet_save('JUB', '[]'::jsonb)
);
