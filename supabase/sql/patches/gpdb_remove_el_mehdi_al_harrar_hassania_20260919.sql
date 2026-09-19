-- One-off: remove duplicate El Mehdi Al Harrar at Hassania Agadir.
-- Keep the Raja Club Athletic card; remap any refs from the Hassania card, then delete it.
-- Safe to re-run (no-ops if the Hassania row is already gone).

DO $$
DECLARE
  v_keep text;
  v_drop text;
  v_keep_club text;
  v_drop_club text;
BEGIN
  -- Prefer the Raja card.
  SELECT p."Konami_ID"::text,
         coalesce(nullif(btrim(c."Club"), ''), nullif(btrim(p."Contracted_Team"), ''))
  INTO v_keep, v_keep_club
  FROM public."Players" p
  LEFT JOIN public."Clubs" c
    ON c."ShortName" = p."Contracted_Team"
  WHERE (
      lower(public.gpdb_normalize_search_text(p."Name"))
        = public.gpdb_normalize_search_text('El Mehdi Al Harrar')
      OR p."Name" ILIKE 'El Mehdi Al Harrar'
    )
    AND (
      p."Contracted_Team" ILIKE '%Raja%'
      OR p."Contracted_Team" ILIKE 'RCA'
      OR c."Club" ILIKE '%Raja%'
    )
  ORDER BY p."Konami_ID"::text
  LIMIT 1;

  SELECT p."Konami_ID"::text,
         coalesce(nullif(btrim(c."Club"), ''), nullif(btrim(p."Contracted_Team"), ''))
  INTO v_drop, v_drop_club
  FROM public."Players" p
  LEFT JOIN public."Clubs" c
    ON c."ShortName" = p."Contracted_Team"
  WHERE (
      lower(public.gpdb_normalize_search_text(p."Name"))
        = public.gpdb_normalize_search_text('El Mehdi Al Harrar')
      OR p."Name" ILIKE 'El Mehdi Al Harrar'
    )
    AND (
      p."Contracted_Team" ILIKE '%Hassania%'
      OR p."Contracted_Team" ILIKE '%Agadir%'
      OR p."Contracted_Team" ILIKE 'HUSA'
      OR c."Club" ILIKE '%Hassania%'
      OR c."Club" ILIKE '%Agadir%'
    )
  ORDER BY p."Konami_ID"::text
  LIMIT 1;

  IF v_drop IS NULL THEN
    RAISE NOTICE 'El Mehdi Al Harrar @ Hassania Agadir not found — nothing to delete.';
    RETURN;
  END IF;

  IF v_keep IS NULL THEN
    RAISE EXCEPTION
      'Keep card (Raja) not found for El Mehdi Al Harrar. Refusing to delete Hassania card % alone.',
      v_drop;
  END IF;

  IF v_keep = v_drop THEN
    RAISE EXCEPTION 'Keep and drop resolved to the same Konami_ID % — aborting.', v_keep;
  END IF;

  RAISE NOTICE 'Keeping % (%); remapping+deleting % (%)',
    v_keep, coalesce(v_keep_club, '?'), v_drop, coalesce(v_drop_club, '?');

  PERFORM public.gpdb_player_remap_id(v_drop, v_keep);

  DELETE FROM public."Players" p
  WHERE p."Konami_ID"::text = v_drop;

  RAISE NOTICE 'Deleted El Mehdi Al Harrar duplicate % (was %).', v_drop, v_drop_club;
END;
$$;
