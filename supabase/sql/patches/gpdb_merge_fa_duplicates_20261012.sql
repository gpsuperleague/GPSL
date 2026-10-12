-- =============================================================================
-- Merge free-agent duplicate cards (2026-10-12)
-- =============================================================================
-- Same player, two GPDB cards, neither signed:
--   153222 Robert Renan      / 16917617 Renan
--   133623 Negueba           / 146072   Emerson Negueba
--   157350 A. Dellavalle     / 165825   Lorenzo Dellavalle
-- Keeps the higher-rated card (then the lower ID), moves any references
-- (favourites, old bids, stats) onto it, and deletes the other.
-- A pair is skipped if either card is contracted or in a live auction.
-- If the delete is blocked by a reference, the card is marked legacy instead.
-- Safe re-run: merged pairs report "already merged".
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _fa_merge_log (pair text, outcome text) ON COMMIT PRESERVE ROWS;
TRUNCATE _fa_merge_log;

DO $merge$
DECLARE
  v_pair text[];
  v_a record;
  v_b record;
  v_keep record;
  v_drop record;
  v_label text;
BEGIN
  FOREACH v_pair SLICE 1 IN ARRAY ARRAY[
    ARRAY['153222', '16917617'],
    ARRAY['133623', '146072'],
    ARRAY['157350', '165825']
  ]
  LOOP
    v_label := v_pair[1] || ' / ' || v_pair[2];

    SELECT "Konami_ID"::text AS id, "Name" AS name,
           nullif(btrim(coalesce("Contracted_Team"::text, '')), '') AS club,
           public.gpdb_player_rating_numeric("Rating"::text) AS rating
    INTO v_a FROM public."Players" WHERE "Konami_ID"::text = v_pair[1];
    SELECT "Konami_ID"::text AS id, "Name" AS name,
           nullif(btrim(coalesce("Contracted_Team"::text, '')), '') AS club,
           public.gpdb_player_rating_numeric("Rating"::text) AS rating
    INTO v_b FROM public."Players" WHERE "Konami_ID"::text = v_pair[2];

    IF v_a.id IS NULL OR v_b.id IS NULL THEN
      INSERT INTO _fa_merge_log VALUES (v_label, 'already merged (only '
        || coalesce(v_a.name || ' ' || v_a.id, v_b.name || ' ' || v_b.id, 'neither') || ' left)');
      CONTINUE;
    END IF;

    IF v_a.club IS NOT NULL OR v_b.club IS NOT NULL THEN
      INSERT INTO _fa_merge_log VALUES (v_label, format('SKIPPED — contracted (%s: %s, %s: %s)',
        v_a.name, coalesce(v_a.club, 'FA'), v_b.name, coalesce(v_b.club, 'FA')));
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public."Player_Transfer_Listings" l
      WHERE btrim(l.player_id::text) IN (v_a.id, v_b.id) AND l.status = 'Active'
    ) THEN
      INSERT INTO _fa_merge_log VALUES (v_label, 'SKIPPED — one card is in a live auction');
      CONTINUE;
    END IF;

    IF coalesce(v_b.rating, -1) > coalesce(v_a.rating, -1)
       OR (coalesce(v_b.rating, -1) = coalesce(v_a.rating, -1) AND v_b.id::numeric < v_a.id::numeric) THEN
      v_keep := v_b; v_drop := v_a;
    ELSE
      v_keep := v_a; v_drop := v_b;
    END IF;

    PERFORM public.gpdb_player_remap_id(v_drop.id, v_keep.id);
    DELETE FROM public.player_draft_max_bids WHERE btrim(player_id) = v_drop.id;

    BEGIN
      DELETE FROM public."Players" WHERE "Konami_ID"::text = v_drop.id;
      INSERT INTO _fa_merge_log VALUES (v_label, format('merged: kept %s %s (%s), deleted %s %s (%s)',
        v_keep.name, v_keep.id, v_keep.rating, v_drop.name, v_drop.id, v_drop.rating));
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Players" SET pesdb_unavailable = true WHERE "Konami_ID"::text = v_drop.id;
      INSERT INTO _fa_merge_log VALUES (v_label, format('kept %s %s; %s %s marked legacy (delete blocked: %s)',
        v_keep.name, v_keep.id, v_drop.name, v_drop.id, SQLERRM));
    END;
  END LOOP;
END
$merge$;

NOTIFY pgrst, 'reload schema';

SELECT pair, outcome FROM _fa_merge_log ORDER BY pair;
