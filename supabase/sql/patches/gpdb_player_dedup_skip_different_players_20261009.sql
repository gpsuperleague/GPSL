-- =============================================================================
-- GPDB dedup — don't merge two different real players with the same name (2026-10-09)
-- =============================================================================
-- Name + Nation alone matched two different Otávios (Brazil: DMF 32 vs CB 24).
-- Now a pair is BLOCKED (shown in preview, never deleted) when:
--   • ages differ by more than 1 year            → 'different_players_age'
--   • either ID is on the "not duplicates" list   → 'marked_not_duplicate'
-- Add more pairs any time:
--   INSERT INTO public.gpdb_player_dedup_ignore (konami_id, note)
--   VALUES ('123', 'reason') ON CONFLICT DO NOTHING;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpdb_player_dedup_ignore (
  konami_id text PRIMARY KEY,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gpdb_player_dedup_ignore ENABLE ROW LEVEL SECURITY;

INSERT INTO public.gpdb_player_dedup_ignore (konami_id, note) VALUES
  ('101455', 'Otávio (Brazil) DMF b.~1994 — different player from 140739'),
  ('140739', 'Otávio (Brazil) CB b.~2002 — different player from 101455')
ON CONFLICT (konami_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.gpdb_player_duplicate_audit()
RETURNS TABLE (
  dup_key text,
  group_size integer,
  blocked_reason text,
  keep_konami_id text,
  keep_name text,
  keep_nation text,
  keep_rating numeric,
  keep_club text,
  drop_konami_id text,
  drop_name text,
  drop_nation text,
  drop_rating numeric,
  drop_club text,
  drop_in_use boolean,
  drop_refs jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  WITH tagged AS (
    SELECT
      p."Konami_ID"::text AS konami_id,
      p."Name" AS player_name,
      p."Nation" AS player_nation,
      public.gpdb_player_duplicate_key(p."Name", p."Nation") AS dup_key,
      public.gpdb_player_rating_numeric(p."Rating"::text) AS rating_num,
      public.gpdb_player_potential_numeric(p."Potential"::text, p."Calc_Potential"::text) AS potential_num,
      nullif(regexp_replace(coalesce(p."Age"::text, ''), '[^0-9]', '', 'g'), '')::int AS age_num,
      nullif(btrim(p."Contracted_Team"), '') AS club_short,
      EXISTS (
        SELECT 1 FROM public.gpdb_player_dedup_ignore i
        WHERE i.konami_id = p."Konami_ID"::text
      ) AS ignored
    FROM public."Players" p
  ),
  group_stats AS (
    SELECT
      t.dup_key,
      count(*)::integer AS group_size,
      count(DISTINCT t.club_short) FILTER (WHERE t.club_short IS NOT NULL)::integer AS distinct_clubs
    FROM tagged t
    WHERE t.dup_key IS NOT NULL
    GROUP BY t.dup_key
    HAVING count(*) > 1
  ),
  ranked AS (
    SELECT
      t.*,
      gs.group_size,
      gs.distinct_clubs,
      row_number() OVER (
        PARTITION BY t.dup_key
        ORDER BY
          t.rating_num DESC NULLS LAST,
          t.potential_num DESC NULLS LAST,
          CASE WHEN t.club_short IS NOT NULL THEN 0 ELSE 1 END,
          t.konami_id ASC
      ) AS rn
    FROM tagged t
    JOIN group_stats gs ON gs.dup_key = t.dup_key
  ),
  winners AS (
    SELECT * FROM ranked WHERE rn = 1
  ),
  losers AS (
    SELECT * FROM ranked WHERE rn > 1
  )
  SELECT
    l.dup_key,
    l.group_size,
    CASE
      WHEN l.ignored OR w.ignored THEN 'marked_not_duplicate'
      WHEN l.age_num IS NOT NULL AND w.age_num IS NOT NULL
           AND abs(l.age_num - w.age_num) > 1 THEN
        format('different_players_age (%s vs %s)', w.age_num, l.age_num)
      WHEN l.distinct_clubs > 1 THEN 'multiple_clubs_contracted'
      ELSE NULL
    END AS blocked_reason,
    w.konami_id AS keep_konami_id,
    w.player_name AS keep_name,
    w.player_nation AS keep_nation,
    w.rating_num AS keep_rating,
    w.club_short AS keep_club,
    l.konami_id AS drop_konami_id,
    l.player_name AS drop_name,
    l.player_nation AS drop_nation,
    l.rating_num AS drop_rating,
    l.club_short AS drop_club,
    public.gpdb_player_id_in_use(l.konami_id) AS drop_in_use,
    public.gpdb_player_id_reference_summary(l.konami_id) AS drop_refs
  FROM losers l
  JOIN winners w ON w.dup_key = l.dup_key
  ORDER BY l.dup_key, l.rating_num DESC NULLS LAST, l.konami_id;
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- Preview: every pair, with ages, and whether it will be merged or skipped
SELECT
  a.keep_name AS player,
  a.keep_konami_id,
  kp."Age" AS keep_age,
  kp."Position" AS keep_pos,
  a.drop_konami_id,
  dp."Age" AS drop_age,
  dp."Position" AS drop_pos,
  coalesce(a.blocked_reason, 'will merge') AS outcome
FROM public.gpdb_player_duplicate_audit() a
LEFT JOIN public."Players" kp ON kp."Konami_ID"::text = a.keep_konami_id
LEFT JOIN public."Players" dp ON dp."Konami_ID"::text = a.drop_konami_id
ORDER BY a.blocked_reason NULLS LAST, a.keep_name;
