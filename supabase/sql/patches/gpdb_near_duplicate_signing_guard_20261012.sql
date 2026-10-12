-- =============================================================================
-- Live block on signing a near-duplicate card (2026-10-12)
-- =============================================================================
-- Two cards are treated as the same player when ALL of these match:
--   • surname (last word of the name) + nation          (accents/case ignored)
--   • position, and playstyle (when both cards have one)
--   • age within 1 year, rating within 2
--   • first names compatible: identical, one card has none ("Renan"), or one
--     is initials with the same first letter ("P. E." vs "Pierre")
-- Cards on gpdb_player_dedup_ignore are never matched.
--
-- Blocks:
--   1) Opening a draft auction (first bid / free pick) on a free agent whose
--      twin is already at a club or already in a live draft auction.
--   2) Backstop: any free agent being given a club while its twin is at a
--      DIFFERENT club (catches every other signing path).
-- Admin override for a one-off: SET LOCAL gpsl.bypass_duplicate_guard = 'on';
-- or mark a false match: INSERT INTO gpdb_player_dedup_ignore (konami_id, note) ...
-- Report at the end: every card pair the rule currently matches.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_player_near_duplicates(p_player_id text)
RETURNS TABLE (konami_id text, player_name text, club text, in_live_draft boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      p."Konami_ID"::text AS id,
      p."Name" AS name,
      nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '') AS club,
      coalesce(p."Position"::text, '') AS pos,
      nullif(btrim(coalesce(p."Playstyle"::text, '')), '') AS ps,
      nullif(regexp_replace(coalesce(p."Age"::text, ''), '[^0-9]', '', 'g'), '')::int AS age,
      public.gpdb_player_rating_numeric(p."Rating"::text) AS rating,
      p."Nation" AS nation
    FROM public."Players" p
    WHERE NOT EXISTS (
      SELECT 1 FROM public.gpdb_player_dedup_ignore i WHERE i.konami_id = p."Konami_ID"::text
    )
  ),
  me AS (
    SELECT b.*,
           public.normalize_nation_key(regexp_replace(btrim(b.name), '^.*[ .]', '')) AS sk,
           btrim(regexp_replace(btrim(b.name), '[ .]*[^ .]+$', '')) AS given,
           public.normalize_nation_key(b.nation) AS nk
    FROM base b
    WHERE b.id = btrim(coalesce(p_player_id, ''))
  ),
  cand AS (
    SELECT o.*,
           btrim(regexp_replace(btrim(o.name), '[ .]*[^ .]+$', '')) AS given
    FROM base o, me
    WHERE o.id <> me.id
      AND o.pos = me.pos
      AND (o.age IS NULL OR me.age IS NULL OR abs(o.age - me.age) <= 1)
      AND (o.rating IS NULL OR me.rating IS NULL OR abs(o.rating - me.rating) <= 2)
      AND (o.ps IS NULL OR me.ps IS NULL OR lower(o.ps) = lower(me.ps))
      AND length(me.sk) >= 3
      AND me.nk <> ''
      AND public.normalize_nation_key(regexp_replace(btrim(o.name), '^.*[ .]', '')) = me.sk
      AND public.normalize_nation_key(o.nation) = me.nk
  )
  SELECT c.id, c.name, c.club,
         EXISTS (
           SELECT 1 FROM public."Player_Transfer_Listings" l
           WHERE btrim(l.player_id::text) = c.id
             AND l.listing_type = 'draft' AND l.status = 'Active'
         )
  FROM cand c, me
  WHERE c.given = '' OR me.given = ''
     OR public.normalize_nation_key(c.given) = public.normalize_nation_key(me.given)
     OR (
       left(public.normalize_nation_key(c.given), 1) = left(public.normalize_nation_key(me.given), 1)
       AND (c.given LIKE '%.%' OR me.given LIKE '%.%' OR length(c.given) <= 2 OR length(me.given) <= 2)
     );
$$;

REVOKE ALL ON FUNCTION public.gpdb_player_near_duplicates(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpdb_player_near_duplicates(text) TO authenticated;

-- 1) Opening a draft auction
CREATE OR REPLACE FUNCTION public.gpdb_draft_listing_duplicate_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_d record;
BEGIN
  IF coalesce(current_setting('gpsl.bypass_duplicate_guard', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  SELECT "Name", nullif(btrim(coalesce("Contracted_Team"::text, '')), '')
  INTO v_name, v_club
  FROM public."Players" WHERE "Konami_ID"::text = btrim(NEW.player_id::text);

  IF v_club IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_d
  FROM public.gpdb_player_near_duplicates(NEW.player_id::text) d
  WHERE d.club IS NOT NULL OR d.in_live_draft
  ORDER BY (d.club IS NOT NULL) DESC
  LIMIT 1;

  IF v_d.konami_id IS NOT NULL THEN
    IF v_d.club IS NOT NULL THEN
      RAISE EXCEPTION '% looks like a duplicate card of % (ID %), already signed by % — this card cannot be signed. Contact the admin if they are different players.',
        coalesce(v_name, NEW.player_id::text), v_d.player_name, v_d.konami_id, v_d.club;
    ELSE
      RAISE EXCEPTION '% looks like a duplicate card of % (ID %), which is already in a live draft auction — bid on that card instead. Contact the admin if they are different players.',
        coalesce(v_name, NEW.player_id::text), v_d.player_name, v_d.konami_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS gpdb_draft_listing_duplicate_guard ON public."Player_Transfer_Listings";
CREATE TRIGGER gpdb_draft_listing_duplicate_guard
  BEFORE INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  WHEN (NEW.listing_type = 'draft')
  EXECUTE FUNCTION public.gpdb_draft_listing_duplicate_guard();

-- 2) Backstop on any signing
CREATE OR REPLACE FUNCTION public.gpdb_player_sign_duplicate_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_new text := upper(nullif(btrim(coalesce(NEW."Contracted_Team"::text, '')), ''));
  v_old text := nullif(btrim(coalesce(OLD."Contracted_Team"::text, '')), '');
  v_d record;
BEGIN
  IF v_new IS NULL OR v_old IS NOT NULL
     OR coalesce(current_setting('gpsl.bypass_duplicate_guard', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_d
  FROM public.gpdb_player_near_duplicates(NEW."Konami_ID"::text) d
  WHERE d.club IS NOT NULL AND upper(d.club) <> v_new
  LIMIT 1;

  IF v_d.konami_id IS NOT NULL THEN
    RAISE EXCEPTION '% looks like a duplicate card of % (ID %), already signed by % — cannot be signed by %. Contact the admin if they are different players.',
      NEW."Name", v_d.player_name, v_d.konami_id, v_d.club, v_new;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS gpdb_player_sign_duplicate_guard ON public."Players";
CREATE TRIGGER gpdb_player_sign_duplicate_guard
  BEFORE UPDATE OF "Contracted_Team" ON public."Players"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpdb_player_sign_duplicate_guard();

NOTIFY pgrst, 'reload schema';

-- Report: every pair the rule matches today (each pair once, signed pairs first)
WITH b AS (
  SELECT
    p."Konami_ID"::text AS id,
    p."Name" AS name,
    nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '') AS club,
    coalesce(p."Position"::text, '') AS pos,
    nullif(btrim(coalesce(p."Playstyle"::text, '')), '') AS ps,
    nullif(regexp_replace(coalesce(p."Age"::text, ''), '[^0-9]', '', 'g'), '')::int AS age,
    public.gpdb_player_rating_numeric(p."Rating"::text) AS rating,
    p."Nation" AS nation,
    coalesce(p.pesdb_unavailable, false) AS legacy,
    public.normalize_nation_key(regexp_replace(btrim(p."Name"), '^.*[ .]', '')) AS sk,
    btrim(regexp_replace(btrim(p."Name"), '[ .]*[^ .]+$', '')) AS given,
    public.normalize_nation_key(p."Nation") AS nk
  FROM public."Players" p
  WHERE NOT EXISTS (
    SELECT 1 FROM public.gpdb_player_dedup_ignore i WHERE i.konami_id = p."Konami_ID"::text
  )
)
SELECT
  CASE
    WHEN x.club IS NOT NULL AND y.club IS NOT NULL THEN '1 BOTH SIGNED'
    WHEN x.club IS NOT NULL OR y.club IS NOT NULL THEN '2 one signed (other now blocked)'
    ELSE '3 both free agents'
  END AS status,
  x.name AS card_a, x.id AS id_a, coalesce(x.club, 'FA') AS club_a, x.legacy AS legacy_a,
  y.name AS card_b, y.id AS id_b, coalesce(y.club, 'FA') AS club_b, y.legacy AS legacy_b,
  x.nation, x.pos, x.age AS age_a, y.age AS age_b, x.rating AS rating_a, y.rating AS rating_b
FROM b x
JOIN b y
  ON y.sk = x.sk AND y.nk = x.nk AND y.pos = x.pos AND y.id > x.id
 AND (x.age IS NULL OR y.age IS NULL OR abs(x.age - y.age) <= 1)
 AND (x.rating IS NULL OR y.rating IS NULL OR abs(x.rating - y.rating) <= 2)
 AND (x.ps IS NULL OR y.ps IS NULL OR lower(x.ps) = lower(y.ps))
WHERE length(x.sk) >= 3 AND x.nk <> ''
  AND (
    x.given = '' OR y.given = ''
    OR public.normalize_nation_key(x.given) = public.normalize_nation_key(y.given)
    OR (
      left(public.normalize_nation_key(x.given), 1) = left(public.normalize_nation_key(y.given), 1)
      AND (x.given LIKE '%.%' OR y.given LIKE '%.%' OR length(x.given) <= 2 OR length(y.given) <= 2)
    )
  )
ORDER BY 1, x.name;
