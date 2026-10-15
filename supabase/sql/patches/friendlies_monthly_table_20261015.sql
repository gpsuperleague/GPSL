-- =============================================================================
-- Friendlies: monthly table + owner prizes (2026-10-15)
--
-- Points per confirmed friendly, by opponent difficulty (1 easiest … 5 hardest):
--   difficulty   win   draw   loss
--       1         2    0.5     0
--       2         3    1       0
--       3         4    1.5     0
--       4         5    2.5     0.5
--       5         6    3       1
--
-- • Difficulty is frozen per GPSL month: the first friendly confirmed in a month
--   snapshots every league club's difficulty (same formula as My Club →
--   Friendlies: owner ranking FDR + Bookies strength), and each friendly stores it.
-- • Only the first 2 friendlies against the same opponent in a month count, and
--   at most the monthly friendly cap (15) per club.
-- • Prize needs 3+ counted friendlies. Order: points, then higher average
--   difficulty, then fewer counted games, then whoever reached their total first.
-- • Every month June → May has its own table; playoffs don't.
-- • At month lock: 1st ₿3,000 / 2nd ₿1,500 to the owner wallet (owner statement
--   "Friendlies table prize"). Clubs without an owner are skipped. Pays once only.
-- • Admin catch-up: SELECT public.admin_gpsl_friendlies_pay_month_prizes('june');
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings (constants)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_table_min_games()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 3; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_table_same_opponent_max()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 2; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_table_prizes()
RETURNS numeric[] LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY[3000, 1500]::numeric[]; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendly_table_points(p_for int, p_against int, p_fdr int)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_fdr int := least(greatest(coalesce(p_fdr, 3), 1), 5);
BEGIN
  IF p_for IS NULL OR p_against IS NULL THEN
    RETURN 0;
  END IF;
  IF p_for > p_against THEN
    RETURN (ARRAY[2, 3, 4, 5, 6]::numeric[])[v_fdr];
  ELSIF p_for = p_against THEN
    RETURN (ARRAY[0.5, 1, 1.5, 2.5, 3]::numeric[])[v_fdr];
  END IF;
  RETURN (ARRAY[0, 0, 0, 0.5, 1]::numeric[])[v_fdr];
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_table_min_games() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_table_same_opponent_max() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_table_prizes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendly_table_points(int, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- Frozen difficulty
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_friendlies
  ADD COLUMN IF NOT EXISTS difficulty_left int,
  ADD COLUMN IF NOT EXISTS difficulty_right int;

COMMENT ON COLUMN public.gpsl_friendlies.difficulty_left IS
  'Difficulty (1-5) of club_right as faced by club_left, frozen for the GPSL month.';
COMMENT ON COLUMN public.gpsl_friendlies.difficulty_right IS
  'Difficulty (1-5) of club_left as faced by club_right, frozen for the GPSL month.';

CREATE TABLE IF NOT EXISTS public.gpsl_friendly_difficulty_snapshots (
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id),
  gpsl_month text NOT NULL,
  fdr_map jsonb NOT NULL,
  computed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, gpsl_month)
);

ALTER TABLE public.gpsl_friendly_difficulty_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_friendly_difficulty_snapshots_read ON public.gpsl_friendly_difficulty_snapshots;
CREATE POLICY gpsl_friendly_difficulty_snapshots_read
  ON public.gpsl_friendly_difficulty_snapshots
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.gpsl_friendly_difficulty_snapshots TO authenticated;
GRANT ALL ON public.gpsl_friendly_difficulty_snapshots TO service_role;

-- Every league club this season → difficulty 1..5 (same formula as
-- club_friendlies_opponent_difficulty)
CREATE OR REPLACE FUNCTION public.gpsl_friendly_fdr_map_compute(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_bookies boolean := to_regprocedure('public.bookies_club_strength(text,bigint)') IS NOT NULL;
  v_has_fdr boolean := to_regprocedure('public.gpfl_fdr_for_club(text)') IS NOT NULL;
  v_strength jsonb := '{}'::jsonb;
  v_pool int := 0;
  v_out jsonb := '{}'::jsonb;
  r record;
  v_rank_fdr int;
  v_book_fdr int;
  v_rank int;
  v_s numeric;
  v_fdr int;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  IF v_has_bookies THEN
    BEGIN
      SELECT coalesce(jsonb_object_agg(x.club, x.strength), '{}'::jsonb)
      INTO v_strength
      FROM (
        SELECT DISTINCT ON (upper(ccs.club_short_name))
               upper(ccs.club_short_name) AS club,
               public.bookies_club_strength(ccs.club_short_name, p_season_id) AS strength
        FROM public.competition_club_seasons ccs
        WHERE ccs.season_id = p_season_id
          AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
      ) x
      WHERE x.strength IS NOT NULL;
    EXCEPTION WHEN OTHERS THEN
      v_strength := '{}'::jsonb;
    END;
    SELECT count(*)::int INTO v_pool FROM jsonb_object_keys(v_strength);
  END IF;

  FOR r IN
    SELECT DISTINCT upper(ccs.club_short_name) AS club
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
  LOOP
    v_rank_fdr := NULL;
    v_book_fdr := NULL;

    IF v_has_fdr THEN
      BEGIN
        SELECT public.gpfl_fdr_for_club(c."ShortName") INTO v_rank_fdr
        FROM public."Clubs" c
        WHERE upper(c."ShortName") = r.club
        LIMIT 1;
      EXCEPTION WHEN OTHERS THEN
        v_rank_fdr := NULL;
      END;
    END IF;

    IF v_pool > 0 AND v_strength ? r.club THEN
      v_s := (v_strength->>r.club)::numeric;
      SELECT count(*)::int + 1 INTO v_rank
      FROM jsonb_each_text(v_strength) e
      WHERE e.value::numeric > v_s;

      v_book_fdr := CASE
        WHEN round(v_rank::numeric * 40 / greatest(v_pool, 1)) <= 4 THEN 5
        WHEN round(v_rank::numeric * 40 / greatest(v_pool, 1)) <= 8 THEN 4
        WHEN round(v_rank::numeric * 40 / greatest(v_pool, 1)) <= 14 THEN 3
        WHEN round(v_rank::numeric * 40 / greatest(v_pool, 1)) <= 22 THEN 2
        ELSE 1
      END;
    END IF;

    v_fdr := CASE
      WHEN v_rank_fdr IS NOT NULL AND v_book_fdr IS NOT NULL
        THEN round((v_rank_fdr + v_book_fdr) / 2.0)::int
      ELSE coalesce(v_rank_fdr, v_book_fdr)
    END;

    IF v_fdr IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(r.club, least(greatest(v_fdr, 1), 5));
    END IF;
  END LOOP;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendly_fdr_map_compute(bigint) FROM PUBLIC, anon, authenticated;

-- Snapshot for a month: computed once (first use), then frozen
CREATE OR REPLACE FUNCTION public.gpsl_friendly_fdr_snapshot(p_season_id bigint, p_gpsl_month text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_map jsonb;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT s.fdr_map INTO v_map
  FROM public.gpsl_friendly_difficulty_snapshots s
  WHERE s.season_id = p_season_id AND s.gpsl_month = v_month;
  IF FOUND THEN
    RETURN v_map;
  END IF;

  v_map := public.gpsl_friendly_fdr_map_compute(p_season_id);
  IF v_map IS NULL OR v_map = '{}'::jsonb THEN
    RETURN '{}'::jsonb;
  END IF;

  INSERT INTO public.gpsl_friendly_difficulty_snapshots (season_id, gpsl_month, fdr_map)
  VALUES (p_season_id, v_month, v_map)
  ON CONFLICT (season_id, gpsl_month) DO NOTHING;

  SELECT s.fdr_map INTO v_map
  FROM public.gpsl_friendly_difficulty_snapshots s
  WHERE s.season_id = p_season_id AND s.gpsl_month = v_month;

  RETURN coalesce(v_map, '{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendly_fdr_snapshot(bigint, text) FROM PUBLIC, anon, authenticated;

-- Stamp difficulty on confirm (never blocks the friendly being saved)
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_stamp_difficulty()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_map jsonb;
BEGIN
  BEGIN
    IF NEW.difficulty_left IS NULL OR NEW.difficulty_right IS NULL THEN
      v_map := public.gpsl_friendly_fdr_snapshot(NEW.season_id, NEW.gpsl_month);
      NEW.difficulty_left := coalesce(NEW.difficulty_left, (v_map->>upper(btrim(NEW.club_right)))::int);
      NEW.difficulty_right := coalesce(NEW.difficulty_right, (v_map->>upper(btrim(NEW.club_left)))::int);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS gpsl_friendlies_stamp_difficulty_trg ON public.gpsl_friendlies;
CREATE TRIGGER gpsl_friendlies_stamp_difficulty_trg
  BEFORE INSERT ON public.gpsl_friendlies
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_friendlies_stamp_difficulty();

-- Fill any friendlies in a month that have no difficulty yet
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_fill_difficulty(p_season_id bigint, p_gpsl_month text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_map jsonb;
  v_n int := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_friendlies f
    WHERE f.season_id = p_season_id
      AND lower(f.gpsl_month) = lower(btrim(p_gpsl_month))
      AND (f.difficulty_left IS NULL OR f.difficulty_right IS NULL)
  ) THEN
    RETURN 0;
  END IF;

  v_map := public.gpsl_friendly_fdr_snapshot(p_season_id, p_gpsl_month);
  IF v_map = '{}'::jsonb THEN
    RETURN 0;
  END IF;

  UPDATE public.gpsl_friendlies f
  SET difficulty_left = coalesce(f.difficulty_left, (v_map->>upper(btrim(f.club_right)))::int),
      difficulty_right = coalesce(f.difficulty_right, (v_map->>upper(btrim(f.club_left)))::int)
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = lower(btrim(p_gpsl_month))
    AND (f.difficulty_left IS NULL OR f.difficulty_right IS NULL);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_fill_difficulty(bigint, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Table rows for one month
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_table_rows(p_season_id bigint, p_gpsl_month text)
RETURNS TABLE (
  place int,
  club text,
  club_name text,
  owner_id uuid,
  played int,
  counted int,
  won int,
  drawn int,
  lost int,
  goals_for int,
  goals_against int,
  points numeric,
  avg_difficulty numeric,
  qualified boolean,
  reached_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH sides AS (
    SELECT f.id, f.confirmed_at,
           upper(btrim(f.club_left)) AS club, upper(btrim(f.club_right)) AS opp,
           f.score_left AS gf, f.score_right AS ga, f.difficulty_left AS fdr
    FROM public.gpsl_friendlies f
    WHERE f.season_id = p_season_id
      AND lower(f.gpsl_month) = lower(btrim(p_gpsl_month))
    UNION ALL
    SELECT f.id, f.confirmed_at,
           upper(btrim(f.club_right)), upper(btrim(f.club_left)),
           f.score_right, f.score_left, f.difficulty_right
    FROM public.gpsl_friendlies f
    WHERE f.season_id = p_season_id
      AND lower(f.gpsl_month) = lower(btrim(p_gpsl_month))
  ),
  vs_opp AS (
    SELECT s.*,
           row_number() OVER (PARTITION BY s.club, s.opp ORDER BY s.confirmed_at, s.id) AS vs_n
    FROM sides s
  ),
  eligible AS (
    SELECT v.*,
           row_number() OVER (PARTITION BY v.club ORDER BY v.confirmed_at, v.id) AS n
    FROM vs_opp v
    WHERE v.vs_n <= public.gpsl_friendlies_table_same_opponent_max()
  ),
  counted AS (
    SELECT e.*, public.gpsl_friendly_table_points(e.gf, e.ga, e.fdr) AS pts
    FROM eligible e
    WHERE e.n <= public.gpsl_friendlies_month_cap()
  ),
  agg AS (
    SELECT c.club,
           count(*)::int AS counted,
           count(*) FILTER (WHERE c.gf > c.ga)::int AS won,
           count(*) FILTER (WHERE c.gf = c.ga)::int AS drawn,
           count(*) FILTER (WHERE c.gf < c.ga)::int AS lost,
           sum(c.gf)::int AS goals_for,
           sum(c.ga)::int AS goals_against,
           sum(c.pts) AS points,
           round(avg(coalesce(c.fdr, 3))::numeric, 2) AS avg_difficulty,
           max(c.confirmed_at) AS reached_at
    FROM counted c
    GROUP BY c.club
  ),
  played AS (
    SELECT s.club, count(*)::int AS played FROM sides s GROUP BY s.club
  )
  SELECT
    row_number() OVER (
      ORDER BY (a.counted >= public.gpsl_friendlies_table_min_games()) DESC,
               a.points DESC, a.avg_difficulty DESC, a.counted ASC, a.reached_at ASC, a.club
    )::int AS place,
    a.club,
    cl."Club" AS club_name,
    cl.owner_id,
    p.played,
    a.counted,
    a.won,
    a.drawn,
    a.lost,
    a.goals_for,
    a.goals_against,
    a.points,
    a.avg_difficulty,
    a.counted >= public.gpsl_friendlies_table_min_games() AS qualified,
    a.reached_at
  FROM agg a
  JOIN played p ON p.club = a.club
  LEFT JOIN LATERAL (
    SELECT c."Club", c.owner_id FROM public."Clubs" c
    WHERE upper(c."ShortName") = a.club
    LIMIT 1
  ) cl ON true
  ORDER BY 1;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_month_table_rows(bigint, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Prize payouts
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpsl_friendlies_prize_payouts (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id),
  gpsl_month text NOT NULL,
  place int NOT NULL CHECK (place >= 1),
  club_short_name text NOT NULL,
  owner_id uuid NOT NULL,
  amount numeric(14, 2) NOT NULL,
  points numeric,
  owner_ledger_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season_id, gpsl_month, place)
);

ALTER TABLE public.gpsl_friendlies_prize_payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_friendlies_prize_payouts_read ON public.gpsl_friendlies_prize_payouts;
CREATE POLICY gpsl_friendlies_prize_payouts_read
  ON public.gpsl_friendlies_prize_payouts
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.gpsl_friendlies_prize_payouts TO authenticated;
GRANT ALL ON public.gpsl_friendlies_prize_payouts TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_pay_month_prizes_internal(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_prizes numeric[] := public.gpsl_friendlies_table_prizes();
  v_place int := 0;
  v_paid int := 0;
  v_skipped int := 0;
  v_total numeric := 0;
  v_ledger bigint;
  v_label text;
  r record;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;
  IF v_month = '' OR v_month = 'playoffs' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_a_prize_month', 'gpsl_month', v_month);
  END IF;

  PERFORM public.gpsl_friendlies_fill_difficulty(p_season_id, v_month);

  v_label := coalesce(public.competition_gpsl_month_label(v_month), initcap(v_month));

  FOR r IN
    SELECT t.*
    FROM public.gpsl_friendlies_month_table_rows(p_season_id, v_month) t
    WHERE t.qualified AND t.owner_id IS NOT NULL
    ORDER BY t.place
  LOOP
    v_place := v_place + 1;
    EXIT WHEN v_place > coalesce(array_length(v_prizes, 1), 0);

    IF EXISTS (
      SELECT 1 FROM public.gpsl_friendlies_prize_payouts p
      WHERE p.season_id = p_season_id AND p.gpsl_month = v_month AND p.place = v_place
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_ledger := public._post_owner_ledger_internal(
      r.owner_id,
      'friendlies_prize',
      v_prizes[v_place],
      format('Friendlies table — %s place, %s (%s, %s pts)',
        CASE v_place WHEN 1 THEN '1st' WHEN 2 THEN '2nd' ELSE v_place::text || 'th' END,
        v_label,
        r.club,
        to_char(r.points, 'FM999990.0')),
      jsonb_build_object(
        'source', 'friendlies_month_table',
        'season_id', p_season_id,
        'gpsl_month', v_month,
        'place', v_place,
        'club', r.club,
        'points', r.points
      ),
      p_season_id,
      true
    );

    INSERT INTO public.gpsl_friendlies_prize_payouts (
      season_id, gpsl_month, place, club_short_name, owner_id, amount, points, owner_ledger_id
    )
    VALUES (
      p_season_id, v_month, v_place, r.club, r.owner_id, v_prizes[v_place], r.points, v_ledger
    );

    v_paid := v_paid + 1;
    v_total := v_total + v_prizes[v_place];
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'season_id', p_season_id,
    'paid', v_paid,
    'skipped', v_skipped,
    'total_amount', v_total
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_pay_month_prizes_internal(bigint, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_gpsl_friendlies_pay_month_prizes(
  p_gpsl_month text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;
  RETURN public.gpsl_friendlies_pay_month_prizes_internal(v_season, p_gpsl_month);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_gpsl_friendlies_pay_month_prizes(text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_gpsl_friendlies_pay_month_prizes(text, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_on_gpsl_month_lock(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_friendlies_pay_month_prizes_internal(p_season_id, p_gpsl_month);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_on_gpsl_month_lock(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_on_gpsl_month_lock(bigint, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Owner-facing: the table for a month (default: active month)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_table(p_gpsl_month text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_active text;
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_months jsonb;
  v_rows jsonb;
  v_winners jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  v_season := public.gpsl_friendlies_live_season_id();
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;
  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  v_active := lower(public.competition_active_gpsl_month(v_season, now()));
  IF v_active = 'playoffs' THEN
    v_active := NULL;
  END IF;

  -- Months with friendlies (plus the active month), in calendar order
  SELECT coalesce(jsonb_agg(
           jsonb_build_object(
             'key', m.gpsl_month,
             'label', coalesce(public.competition_gpsl_month_label(m.gpsl_month), initcap(m.gpsl_month)),
             'paid', EXISTS (
               SELECT 1 FROM public.gpsl_friendlies_prize_payouts p
               WHERE p.season_id = v_season AND p.gpsl_month = m.gpsl_month
             )
           ) ORDER BY m.sort_at, m.gpsl_month
         ), '[]'::jsonb)
  INTO v_months
  FROM (
    SELECT x.gpsl_month, min(cal.unlock_at) AS sort_at
    FROM (
      SELECT DISTINCT lower(f.gpsl_month) AS gpsl_month
      FROM public.gpsl_friendlies f
      WHERE f.season_id = v_season
      UNION
      SELECT v_active WHERE v_active IS NOT NULL
    ) x
    LEFT JOIN public.competition_season_calendar cal
      ON cal.season_id = v_season AND lower(cal.gpsl_month) = x.gpsl_month
    WHERE x.gpsl_month IS NOT NULL AND x.gpsl_month <> 'playoffs'
    GROUP BY x.gpsl_month
  ) m;

  IF v_month IS NULL THEN
    v_month := coalesce(v_active, (v_months->(jsonb_array_length(v_months) - 1))->>'key');
  END IF;

  IF v_month IS NULL OR v_month = 'playoffs' THEN
    RETURN jsonb_build_object(
      'ok', true, 'season_id', v_season, 'month', NULL, 'months', v_months, 'rows', '[]'::jsonb,
      'winners', '[]'::jsonb, 'min_games', public.gpsl_friendlies_table_min_games(),
      'prizes', to_jsonb(public.gpsl_friendlies_table_prizes()),
      'my_club', upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''))
    );
  END IF;

  SELECT coalesce(jsonb_agg(
           jsonb_build_object(
             'place', t.place,
             'club', t.club,
             'club_name', t.club_name,
             'has_owner', t.owner_id IS NOT NULL,
             'played', t.played,
             'counted', t.counted,
             'won', t.won,
             'drawn', t.drawn,
             'lost', t.lost,
             'goals_for', t.goals_for,
             'goals_against', t.goals_against,
             'points', t.points,
             'avg_difficulty', t.avg_difficulty,
             'qualified', t.qualified
           ) ORDER BY t.place
         ), '[]'::jsonb)
  INTO v_rows
  FROM public.gpsl_friendlies_month_table_rows(v_season, v_month) t;

  SELECT coalesce(jsonb_agg(
           jsonb_build_object('place', p.place, 'club', p.club_short_name, 'amount', p.amount, 'points', p.points)
           ORDER BY p.place
         ), '[]'::jsonb)
  INTO v_winners
  FROM public.gpsl_friendlies_prize_payouts p
  WHERE p.season_id = v_season AND p.gpsl_month = v_month;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'month', v_month,
    'month_label', coalesce(public.competition_gpsl_month_label(v_month), initcap(v_month)),
    'is_active_month', v_month = v_active,
    'months', v_months,
    'rows', v_rows,
    'winners', v_winners,
    'min_games', public.gpsl_friendlies_table_min_games(),
    'same_opponent_max', public.gpsl_friendlies_table_same_opponent_max(),
    'month_cap', public.gpsl_friendlies_month_cap(),
    'prizes', to_jsonb(public.gpsl_friendlies_table_prizes()),
    'my_club', upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_month_table(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_month_table(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Month-lock wire (pays the month that just locked)
-- ---------------------------------------------------------------------------
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'gpsl_friendlies_on_gpsl_month_lock';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs(4-arg) missing — friendlies prize wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL OR position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Friendlies prizes already wired (or month-lock missing)';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out — friendlies prize wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  -- Friendlies monthly table: owner prizes for the month that just locked\n'
    || E'  IF coalesce(v_month, '''') NOT IN ('''', ''playoffs'')\n'
    || E'     AND coalesce(nullif(v_stage, ''''), ''all'') IN (''all'', ''tables'', ''league_tables'', ''awards'', ''friendlies'')\n'
    || E'  THEN\n'
    || E'    BEGIN\n'
    || E'      IF to_regprocedure(''public.gpsl_friendlies_on_gpsl_month_lock(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_out := v_out || jsonb_build_object(\n'
    || E'          ''friendlies_prizes'',\n'
    || E'          public.gpsl_friendlies_on_gpsl_month_lock(p_season_id, v_month)\n'
    || E'        );\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''friendlies_prizes'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n'
    || E'  END IF;\n\n'
    || E'  RETURN v_out;\nEND;';

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired friendlies prizes into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Friendlies prize wire failed: %', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Backfill difficulty for this season's friendlies (one snapshot per month)
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_season bigint;
  m record;
BEGIN
  SELECT id INTO v_season FROM public.competition_seasons
  WHERE is_current = true ORDER BY id DESC LIMIT 1;
  IF v_season IS NULL THEN
    RETURN;
  END IF;
  FOR m IN
    SELECT DISTINCT lower(f.gpsl_month) AS gpsl_month
    FROM public.gpsl_friendlies f
    WHERE f.season_id = v_season
  LOOP
    PERFORM public.gpsl_friendlies_fill_difficulty(v_season, m.gpsl_month);
  END LOOP;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';

-- Report: wired into month-end, difficulty coverage, and the top 5 per month
WITH cur AS (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
),
wired AS (
  SELECT position('gpsl_friendlies_on_gpsl_month_lock' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0 AS ok
),
months AS (
  SELECT DISTINCT lower(f.gpsl_month) AS gpsl_month
  FROM public.gpsl_friendlies f, cur
  WHERE f.season_id = cur.id
)
SELECT
  m.gpsl_month,
  (SELECT ok FROM wired) AS wired_into_month_lock,
  (SELECT count(*) FROM public.gpsl_friendlies f, cur
    WHERE f.season_id = cur.id AND lower(f.gpsl_month) = m.gpsl_month) AS friendlies,
  (SELECT count(*) FROM public.gpsl_friendlies f, cur
    WHERE f.season_id = cur.id AND lower(f.gpsl_month) = m.gpsl_month
      AND (f.difficulty_left IS NULL OR f.difficulty_right IS NULL)) AS missing_difficulty,
  (SELECT string_agg(
            format('%s. %s %s pts (%s games, avg diff %s)%s',
                   t.place, t.club, to_char(t.points, 'FM999990.0'), t.counted, t.avg_difficulty,
                   CASE WHEN t.qualified THEN '' ELSE ' — not qualified' END),
            ' | ' ORDER BY t.place)
     FROM public.gpsl_friendlies_month_table_rows((SELECT id FROM cur), m.gpsl_month) t
     WHERE t.place <= 5) AS top_5
FROM months m
ORDER BY m.gpsl_month;
