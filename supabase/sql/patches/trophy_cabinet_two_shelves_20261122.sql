-- Cabinet display: 2 shelves, 10 places each.
-- Places that no longer fit are moved into the store room.

ALTER TABLE public.competition_trophy_cabinet_place
  DROP CONSTRAINT IF EXISTS competition_trophy_cabinet_place_spot;

UPDATE public.competition_trophy_cabinet_place
SET stored = true,
    shelf = NULL,
    slot = NULL,
    updated_at = now()
WHERE NOT stored
  AND (shelf > 1 OR slot > 9 OR shelf < 0 OR slot < 0);

ALTER TABLE public.competition_trophy_cabinet_place
  ADD CONSTRAINT competition_trophy_cabinet_place_spot CHECK (
    (stored AND shelf IS NULL AND slot IS NULL)
    OR (
      NOT stored
      AND shelf BETWEEN 0 AND 1
      AND slot BETWEEN 0 AND 9
    )
  );

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
      OR v_shelf < 0 OR v_shelf > 1
      OR v_slot < 0 OR v_slot > 9 THEN
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

SELECT public.competition_trophy_cabinet_get('JUB');
