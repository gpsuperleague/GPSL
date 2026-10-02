-- =============================================================================
-- Club commercial income (2026-10-02)
--
-- Three Central Bank–funded income streams per club per season, banded by
-- prestige tier (competition_club_tier) and scaled by league + cup results
-- against targets (competition_stadium_season_metrics):
--
--   * Main sponsor   — 3 offers from fictional brands at season start
--                      (long 2 seasons @ ~80% / short 1 season @ 100% /
--                       performance: low base + bonus at Close Finances).
--                      Auto-picks the long deal if nobody chooses by the deadline.
--   * Pitchside ads  — 5 boards sold at season start, priced on last season.
--   * Merchandising  — club shop + global kit sales, paid at Close Finances.
--
-- Bands (per stream, editable in Admin → Commercial income):
--   big ₿3m–₿6m · medium ₿1m–₿3m · low ₿0–₿1m
--
-- Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Ledger entry types (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $ledger_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_finance_ledger'::regclass
    AND c.conname = 'competition_finance_ledger_entry_type_check';

  IF v_def IS NULL THEN
    RAISE NOTICE 'No ledger entry_type constraint — nothing to widen';
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT unnest(ARRAY['commercial_sponsorship', 'commercial_advertising', 'commercial_merchandise'])
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_finance_ledger
    VALIDATE CONSTRAINT competition_finance_ledger_entry_type_check;
END;
$ledger_types$;

-- ---------------------------------------------------------------------------
-- 2. Central Bank routing — add the three types to the live function
-- ---------------------------------------------------------------------------
DO $cb_types$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.finance_entry_via_central_bank(text)') IS NULL THEN
    RAISE NOTICE 'finance_entry_via_central_bank missing — skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.finance_entry_via_central_bank(text)'::regprocedure)
  INTO v_def;

  IF v_def LIKE '%commercial_sponsorship%' THEN
    RETURN;
  END IF;

  IF position('ARRAY[' IN v_def) = 0 THEN
    RAISE NOTICE 'finance_entry_via_central_bank has no ARRAY[ list — skipped (bank leg still posted by commercial helper)';
    RETURN;
  END IF;

  v_def := regexp_replace(
    v_def,
    'ARRAY\[',
    'ARRAY[''commercial_sponsorship'', ''commercial_advertising'', ''commercial_merchandise'', '
  );
  EXECUTE v_def;
END;
$cb_types$;

-- ---------------------------------------------------------------------------
-- 3. Inbox message type: commercial_offer (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'commercial_offer'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- 4. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.club_commercial_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT true,
  big_min numeric(14, 2) NOT NULL DEFAULT 3000000,
  big_max numeric(14, 2) NOT NULL DEFAULT 6000000,
  medium_min numeric(14, 2) NOT NULL DEFAULT 1000000,
  medium_max numeric(14, 2) NOT NULL DEFAULT 3000000,
  low_min numeric(14, 2) NOT NULL DEFAULT 0,
  low_max numeric(14, 2) NOT NULL DEFAULT 1000000,
  min_value_pct numeric NOT NULL DEFAULT 0.15,
  long_deal_pct numeric NOT NULL DEFAULT 0.80,
  perf_deal_base_pct numeric NOT NULL DEFAULT 0.40,
  offer_days int NOT NULL DEFAULT 7,
  merch_fill_weight numeric NOT NULL DEFAULT 0.30,
  shop_share numeric NOT NULL DEFAULT 0.60,
  score_on_target numeric NOT NULL DEFAULT 0.60,
  score_floor_ratio numeric NOT NULL DEFAULT 0.50,
  score_ceiling_ratio numeric NOT NULL DEFAULT 1.40,
  default_score numeric NOT NULL DEFAULT 0.50,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.club_commercial_settings (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.commercial_brands (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name text NOT NULL UNIQUE,
  sector text NOT NULL,
  tagline text,
  tier_pref text NOT NULL DEFAULT 'standard'
    CHECK (tier_pref IN ('premium', 'standard', 'local')),
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.club_commercial_sponsor_offers (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  season_id bigint NOT NULL,
  club_short_name text NOT NULL,
  brand_id bigint NOT NULL REFERENCES public.commercial_brands (id),
  deal_kind text NOT NULL CHECK (deal_kind IN ('long', 'short', 'performance')),
  seasons int NOT NULL DEFAULT 1,
  amount_per_season numeric(14, 2) NOT NULL DEFAULT 0,
  base_amount numeric(14, 2),
  max_amount numeric(14, 2),
  band_min numeric(14, 2) NOT NULL DEFAULT 0,
  band_max numeric(14, 2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'offered'
    CHECK (status IN ('offered', 'accepted', 'declined', 'expired')),
  expires_at timestamptz NOT NULL,
  decided_at timestamptz,
  decided_by uuid,
  auto_selected boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season_id, club_short_name, deal_kind)
);

CREATE TABLE IF NOT EXISTS public.club_commercial_sponsorships (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  club_short_name text NOT NULL,
  brand_id bigint NOT NULL REFERENCES public.commercial_brands (id),
  offer_id bigint REFERENCES public.club_commercial_sponsor_offers (id),
  deal_kind text NOT NULL CHECK (deal_kind IN ('long', 'short', 'performance')),
  start_season_id bigint NOT NULL,
  seasons_total int NOT NULL DEFAULT 1,
  amount_per_season numeric(14, 2) NOT NULL DEFAULT 0,
  base_amount numeric(14, 2),
  max_amount numeric(14, 2),
  band_min numeric(14, 2) NOT NULL DEFAULT 0,
  band_max numeric(14, 2) NOT NULL DEFAULT 0,
  auto_selected boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (club_short_name, start_season_id)
);

CREATE TABLE IF NOT EXISTS public.club_commercial_sponsorship_payments (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  sponsorship_id bigint NOT NULL REFERENCES public.club_commercial_sponsorships (id) ON DELETE CASCADE,
  season_id bigint NOT NULL,
  kind text NOT NULL CHECK (kind IN ('season', 'performance_bonus')),
  amount numeric(14, 2) NOT NULL DEFAULT 0,
  ledger_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sponsorship_id, season_id, kind)
);

CREATE TABLE IF NOT EXISTS public.club_commercial_boards (
  season_id bigint NOT NULL,
  club_short_name text NOT NULL,
  slot smallint NOT NULL CHECK (slot BETWEEN 1 AND 5),
  brand_id bigint NOT NULL REFERENCES public.commercial_brands (id),
  amount numeric(14, 2) NOT NULL DEFAULT 0,
  ledger_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, club_short_name, slot)
);

CREATE TABLE IF NOT EXISTS public.club_commercial_merch (
  season_id bigint NOT NULL,
  club_short_name text NOT NULL,
  perf_score numeric,
  fill_score numeric,
  shop_amount numeric(14, 2) NOT NULL DEFAULT 0,
  global_amount numeric(14, 2) NOT NULL DEFAULT 0,
  shop_ledger_id bigint,
  global_ledger_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, club_short_name)
);

CREATE INDEX IF NOT EXISTS club_commercial_offers_club_idx
  ON public.club_commercial_sponsor_offers (club_short_name, season_id);
CREATE INDEX IF NOT EXISTS club_commercial_sponsorships_club_idx
  ON public.club_commercial_sponsorships (club_short_name, start_season_id DESC);

-- RLS: everyone signed in can read; writes go through SECURITY DEFINER RPCs.
DO $rls$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'club_commercial_settings', 'commercial_brands', 'club_commercial_sponsor_offers',
    'club_commercial_sponsorships', 'club_commercial_sponsorship_payments',
    'club_commercial_boards', 'club_commercial_merch'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)',
      t || '_read', t
    );
  END LOOP;
END;
$rls$;

DROP POLICY IF EXISTS club_commercial_settings_admin ON public.club_commercial_settings;
CREATE POLICY club_commercial_settings_admin ON public.club_commercial_settings
  FOR UPDATE TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS commercial_brands_admin ON public.commercial_brands;
CREATE POLICY commercial_brands_admin ON public.commercial_brands
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.club_commercial_settings, public.commercial_brands,
  public.club_commercial_sponsor_offers, public.club_commercial_sponsorships,
  public.club_commercial_sponsorship_payments, public.club_commercial_boards,
  public.club_commercial_merch TO authenticated;
GRANT UPDATE ON public.club_commercial_settings TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.commercial_brands TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Brand pool (fictional)
-- ---------------------------------------------------------------------------
INSERT INTO public.commercial_brands (name, sector, tagline, tier_pref) VALUES
  -- premium
  ('Volta Motors', 'Electric cars', 'Charge ahead.', 'premium'),
  ('Northgate Bank', 'Banking', 'Banking for the long game.', 'premium'),
  ('Aurelia Watches', 'Luxury watches', 'Every second counts.', 'premium'),
  ('Skyline Airways', 'International airline', 'The world, upgraded.', 'premium'),
  ('Nimbus Mobile', 'Mobile network', 'Signal from every stand.', 'premium'),
  ('Meridian Insurance', 'Insurance', 'Covered from kick-off.', 'premium'),
  ('Crown & Anchor Hotels', 'Luxury hotels', 'Five stars, every night.', 'premium'),
  ('Orbital Tech', 'Computing', 'Think in orbit.', 'premium'),
  ('Halcyon Resorts', 'Holiday resorts', 'Your off-season, sorted.', 'premium'),
  ('Apex Fuels', 'Energy', 'Powering the top flight.', 'premium'),
  ('Silverline Rail', 'High-speed rail', 'Home and away, on time.', 'premium'),
  ('Quantum Cloud', 'Cloud computing', 'Data at full tilt.', 'premium'),
  ('Regal Cola', 'Soft drinks', 'The taste of champions.', 'premium'),
  ('Zenith Capital', 'Investment', 'Aim for the top.', 'premium'),
  ('Lumen Electronics', 'Televisions', 'See every blade of grass.', 'premium'),
  ('Atlas Logistics', 'Global shipping', 'We carry the weight.', 'premium'),
  -- standard
  ('Low Air', 'Budget flights', 'Fly low, pay lower.', 'standard'),
  ('Lovely Buttery', 'Spreads', 'Spread the love.', 'standard'),
  ('Fizzpop', 'Soft drinks', 'Pop goes the weekend.', 'standard'),
  ('Brew Brothers', 'Coffee', 'Half-time, every time.', 'standard'),
  ('Bytewave Broadband', 'Broadband', 'Buffer-free football.', 'standard'),
  ('Pixel Forge', 'Video games', 'Press start.', 'standard'),
  ('Sole Mate', 'Trainers', 'Made for match day.', 'standard'),
  ('Zappo Energy', 'Energy drinks', 'Ninety minutes of zap.', 'standard'),
  ('Crunchwell Crisps', 'Crisps', 'The loudest crunch in the ground.', 'standard'),
  ('Snugglebed', 'Mattresses', 'Rest like a champion.', 'standard'),
  ('Kwik Klean', 'Laundry', 'Gets the grass stains out.', 'standard'),
  ('Golden Crumb', 'Bakery', 'Baked fresh, every match day.', 'standard'),
  ('Moo & Co', 'Dairy', 'Udderly brilliant.', 'standard'),
  ('Sky Pillow Hotels', 'Hotels', 'Sleep easy on away days.', 'standard'),
  ('Trusty Tyres', 'Tyres', 'Grip when it matters.', 'standard'),
  ('Sparkle Smile', 'Toothpaste', 'Celebrate with a grin.', 'standard'),
  ('Chillbox', 'Ice cream', 'Cool under pressure.', 'standard'),
  ('Pawfect', 'Pet food', 'Loyal like a supporter.', 'standard'),
  ('Rapid Rentals', 'Car hire', 'Get to the game.', 'standard'),
  ('DriftWave', 'Headphones', 'Hear the roar.', 'standard'),
  ('FitFuel', 'Fitness app', 'Train like the pros.', 'standard'),
  ('Homely Homes', 'House builders', 'Build from the back.', 'standard'),
  -- local
  ('Puddle Boots', 'Wellies', 'For the wettest away ends.', 'local'),
  ('Dave''s Vans', 'Removals', 'We move, you cheer.', 'local'),
  ('The Pie Shed', 'Pies', 'Half-time hero.', 'local'),
  ('Corner Cuts', 'Barbers', 'A fresh fade for match day.', 'local'),
  ('Mabel''s Tearoom', 'Café', 'A proper brew.', 'local'),
  ('Kev''s Kebabs', 'Takeaway', 'Post-match tradition.', 'local'),
  ('Sparky Sid', 'Electricians', 'Floodlights fixed fast.', 'local'),
  ('Bloom & Grow', 'Garden centre', 'Greener than the pitch.', 'local'),
  ('FixIt Phones', 'Phone repairs', 'Cracked screen? Sorted.', 'local'),
  ('Sunny Side Café', 'Breakfasts', 'Full English, full stadium.', 'local'),
  ('Plumb Perfect', 'Plumbing', 'No leaks at the back.', 'local'),
  ('Tidy Paws', 'Dog grooming', 'Best in show.', 'local'),
  ('Hilltop Dairy', 'Milk rounds', 'Delivered before dawn.', 'local'),
  ('Rolling Pin Bakery', 'Bakery', 'Rise with us.', 'local'),
  ('Lucky Lane Laundrette', 'Laundrette', 'Clean sheets guaranteed.', 'local'),
  ('Granny Smith''s Chutney', 'Preserves', 'Tangy since 1952.', 'local'),
  ('Turbo Exhausts', 'Garage', 'MOTs while you watch.', 'local'),
  ('The Pint & Pitch', 'Pub', 'Every game, every screen.', 'local'),
  ('Clean Sweep Chimneys', 'Chimney sweeps', 'A clean sweep, every season.', 'local'),
  ('Byte-Size Computers', 'Computer repairs', 'Little shop, big fixes.', 'local')
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_commercial_round(p_amount numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(0, round(coalesce(p_amount, 0) / 10000.0) * 10000);
$$;

CREATE OR REPLACE FUNCTION public.club_commercial_tier(p_club_short_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tier text;
BEGIN
  BEGIN
    v_tier := public.competition_club_tier(p_club_short_name);
  EXCEPTION WHEN OTHERS THEN
    v_tier := NULL;
  END;
  RETURN CASE WHEN v_tier IN ('big', 'medium', 'low') THEN v_tier ELSE 'low' END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_commercial_band(p_tier text)
RETURNS numeric[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE p_tier
    WHEN 'big' THEN ARRAY[s.big_min, s.big_max]
    WHEN 'medium' THEN ARRAY[s.medium_min, s.medium_max]
    ELSE ARRAY[s.low_min, s.low_max]
  END
  FROM public.club_commercial_settings s
  WHERE s.id = 1;
$$;

-- Band value for a 0..1 score, never below min_value_pct of the band max.
CREATE OR REPLACE FUNCTION public.club_commercial_value(p_tier text, p_score numeric)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_commercial_round(
    greatest(
      b[1] + least(1, greatest(0, coalesce(p_score, s.default_score))) * (b[2] - b[1]),
      b[2] * s.min_value_pct
    )
  )
  FROM public.club_commercial_settings s,
       LATERAL (SELECT public.club_commercial_band(p_tier) AS b) x
  WHERE s.id = 1;
$$;

-- Seasons elapsed since p_start (0 = same season, -1 = before start).
CREATE OR REPLACE FUNCTION public.club_commercial_season_offset(p_start bigint, p_season bigint)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_season < p_start THEN -1
    ELSE (
      SELECT count(*)::int
      FROM public.competition_seasons cs
      WHERE cs.id > p_start AND cs.id <= p_season
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.club_commercial_prev_season(p_season bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT max(cs.id) FROM public.competition_seasons cs WHERE cs.id < p_season;
$$;

CREATE OR REPLACE FUNCTION public.club_commercial_in_season(p_club text, p_season bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season
      AND ccs.club_short_name = p_club
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  );
$$;

-- League + cup results vs targets → 0..1 (on target ≈ 0.6).
CREATE OR REPLACE FUNCTION public.club_commercial_perf_score(p_club text, p_season bigint)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  m jsonb;
  v_exp numeric;
  v_act numeric;
  r numeric;
BEGIN
  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;

  IF p_season IS NULL OR NOT public.club_commercial_in_season(p_club, p_season) THEN
    RETURN s.default_score;
  END IF;

  BEGIN
    m := public.competition_stadium_season_metrics(p_club, p_season, NULL);
  EXCEPTION WHEN OTHERS THEN
    RETURN s.default_score;
  END;

  IF m IS NULL OR m ? 'error' THEN
    RETURN s.default_score;
  END IF;

  BEGIN
    v_exp := nullif(m->>'expected_points', '')::numeric;
    v_act := nullif(m->>'actual_points', '')::numeric;
  EXCEPTION WHEN OTHERS THEN
    RETURN s.default_score;
  END;

  IF v_exp IS NULL OR v_exp <= 0 OR v_act IS NULL THEN
    RETURN s.default_score;
  END IF;

  r := v_act / v_exp;

  IF r <= 1 THEN
    RETURN round(least(1, greatest(0,
      s.score_on_target * greatest(0, (r - s.score_floor_ratio) / nullif(1 - s.score_floor_ratio, 0))
    )), 4);
  END IF;

  RETURN round(least(1, greatest(0,
    s.score_on_target + (1 - s.score_on_target)
      * least(1, (r - 1) / nullif(s.score_ceiling_ratio - 1, 0))
  )), 4);
END;
$function$;

-- Stadium fill vs the club's fill range → 0..1.
CREATE OR REPLACE FUNCTION public.club_commercial_fill_score(p_club text, p_season bigint)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  m jsonb;
  v_fill numeric;
  v_min numeric;
  v_max numeric;
BEGIN
  IF p_season IS NULL OR NOT public.club_commercial_in_season(p_club, p_season) THEN
    RETURN 0.5;
  END IF;

  BEGIN
    m := public.competition_stadium_season_metrics(p_club, p_season, NULL);
    v_fill := nullif(m->>'season_target_fill_pct', '')::numeric;
    v_min := nullif(m->>'min_fill_pct', '')::numeric;
    v_max := nullif(m->>'max_display_fill_pct', '')::numeric;
  EXCEPTION WHEN OTHERS THEN
    RETURN 0.5;
  END;

  IF v_fill IS NULL OR v_min IS NULL OR v_max IS NULL OR v_max <= v_min THEN
    RETURN 0.5;
  END IF;

  RETURN round(least(1, greatest(0, (v_fill - v_min) / (v_max - v_min))), 4);
END;
$function$;

-- Post a Central Bank–funded credit; guarantees the bank leg exists exactly once.
CREATE OR REPLACE FUNCTION public.club_commercial_post(
  p_club text,
  p_entry_type text,
  p_amount numeric,
  p_description text,
  p_metadata jsonb,
  p_season_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF coalesce(p_amount, 0) <= 0 THEN
    RETURN NULL;
  END IF;

  v_id := public.post_club_ledger(
    p_club, p_entry_type, p_amount, p_description,
    coalesce(p_metadata, '{}'::jsonb), p_season_id, NULL, true, true
  );

  IF v_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_id) THEN
    UPDATE public.gpsl_bank_account
    SET reserves = reserves - p_amount,
        updated_at = now()
    WHERE id = 1;

    INSERT INTO public.bank_ledger (
      entry_type, amount, description, club_short_name, club_ledger_id, metadata
    ) VALUES (
      p_entry_type, -p_amount, p_description, p_club, v_id, coalesce(p_metadata, '{}'::jsonb)
    );
  END IF;

  RETURN v_id;
END;
$function$;

-- Contract covering a season (most recent start wins).
CREATE OR REPLACE FUNCTION public.club_commercial_active_sponsorship(p_club text, p_season bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id
  FROM public.club_commercial_sponsorships s
  WHERE s.club_short_name = p_club
    AND s.start_season_id <= p_season
    AND public.club_commercial_season_offset(s.start_season_id, p_season) < s.seasons_total
  ORDER BY s.start_season_id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.club_commercial_pay_sponsor_season(
  p_sponsorship_id bigint,
  p_season_id bigint
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  c public.club_commercial_sponsorships;
  v_brand text;
  v_amount numeric;
  v_pay_id bigint;
  v_ledger bigint;
  v_n int;
BEGIN
  SELECT * INTO c FROM public.club_commercial_sponsorships WHERE id = p_sponsorship_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT name INTO v_brand FROM public.commercial_brands WHERE id = c.brand_id;
  v_amount := CASE WHEN c.deal_kind = 'performance' THEN coalesce(c.base_amount, 0)
                   ELSE c.amount_per_season END;
  v_n := public.club_commercial_season_offset(c.start_season_id, p_season_id) + 1;

  INSERT INTO public.club_commercial_sponsorship_payments (sponsorship_id, season_id, kind, amount)
  VALUES (c.id, p_season_id, 'season', v_amount)
  ON CONFLICT (sponsorship_id, season_id, kind) DO NOTHING
  RETURNING id INTO v_pay_id;

  IF v_pay_id IS NULL THEN
    RETURN 0;
  END IF;

  v_ledger := public.club_commercial_post(
    c.club_short_name,
    'commercial_sponsorship',
    v_amount,
    format('Main sponsor: %s (season %s of %s)', v_brand, v_n, c.seasons_total),
    jsonb_build_object('sponsorship_id', c.id, 'brand', v_brand, 'deal_kind', c.deal_kind, 'kind', 'season'),
    p_season_id
  );

  UPDATE public.club_commercial_sponsorship_payments SET ledger_id = v_ledger WHERE id = v_pay_id;
  RETURN v_amount;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_commercial_accept_internal(
  p_offer_id bigint,
  p_auto boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  o public.club_commercial_sponsor_offers;
  v_contract bigint;
BEGIN
  SELECT * INTO o FROM public.club_commercial_sponsor_offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offer not found';
  END IF;
  IF o.status <> 'offered' THEN
    RAISE EXCEPTION 'This offer is no longer available';
  END IF;
  IF public.club_commercial_active_sponsorship(o.club_short_name, o.season_id) IS NOT NULL THEN
    RAISE EXCEPTION 'Club already has a main sponsor this season';
  END IF;

  UPDATE public.club_commercial_sponsor_offers
  SET status = 'accepted', decided_at = now(),
      decided_by = CASE WHEN p_auto THEN NULL ELSE auth.uid() END,
      auto_selected = p_auto
  WHERE id = o.id;

  UPDATE public.club_commercial_sponsor_offers
  SET status = CASE WHEN p_auto THEN 'expired' ELSE 'declined' END, decided_at = now()
  WHERE season_id = o.season_id
    AND club_short_name = o.club_short_name
    AND id <> o.id
    AND status = 'offered';

  INSERT INTO public.club_commercial_sponsorships (
    club_short_name, brand_id, offer_id, deal_kind, start_season_id, seasons_total,
    amount_per_season, base_amount, max_amount, band_min, band_max, auto_selected
  ) VALUES (
    o.club_short_name, o.brand_id, o.id, o.deal_kind, o.season_id, o.seasons,
    o.amount_per_season, o.base_amount, o.max_amount, o.band_min, o.band_max, p_auto
  )
  RETURNING id INTO v_contract;

  PERFORM public.club_commercial_pay_sponsor_season(v_contract, o.season_id);
  RETURN v_contract;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_commercial_season_open(p_season bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.competition_seasons cs
    WHERE cs.id = p_season AND cs.status IN ('setup', 'preseason', 'active')
  );
$$;

CREATE OR REPLACE FUNCTION public.club_commercial_current_season()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY
    CASE status
      WHEN 'active' THEN 0 WHEN 'preseason' THEN 1 WHEN 'setup' THEN 2
      WHEN 'summer_break' THEN 3 ELSE 4
    END,
    id DESC
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- 7. Season start for one club: boards, sponsor payment or offers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_commercial_ensure_season(p_club text, p_season bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  v_tier text;
  v_band numeric[];
  v_pref text;
  v_prev bigint;
  v_score numeric;
  v_value numeric;
  v_total numeric;
  v_weights numeric[] := ARRAY[0.30, 0.24, 0.19, 0.15, 0.12];
  v_slot int := 0;
  v_amt numeric;
  v_left numeric;
  v_ledger bigint;
  v_brand record;
  v_contract bigint;
  v_owner uuid;
  v_expired_long bigint;
  v_offers_made boolean := false;
  v_names text[];
  v_long numeric;
  v_short numeric;
  v_base numeric;
BEGIN
  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;
  IF NOT coalesce(s.enabled, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'disabled');
  END IF;
  IF NOT public.club_commercial_season_open(p_season) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'season_closed');
  END IF;
  IF NOT public.club_commercial_in_season(p_club, p_season) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_season');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('club_commercial:' || p_club || ':' || p_season));

  v_tier := public.club_commercial_tier(p_club);
  v_band := public.club_commercial_band(v_tier);
  v_pref := CASE v_tier WHEN 'big' THEN 'premium' WHEN 'medium' THEN 'standard' ELSE 'local' END;
  v_prev := public.club_commercial_prev_season(p_season);
  v_score := public.club_commercial_perf_score(p_club, v_prev);
  v_value := public.club_commercial_value(v_tier, v_score);

  SELECT owner_id INTO v_owner FROM public."Clubs" WHERE "ShortName" = p_club;

  -- Pitchside boards (once per season)
  IF NOT EXISTS (
    SELECT 1 FROM public.club_commercial_boards
    WHERE season_id = p_season AND club_short_name = p_club
  ) THEN
    v_total := v_value;
    v_left := v_total;
    FOR v_brand IN
      SELECT b.id, b.name
      FROM public.commercial_brands b
      WHERE b.active
      ORDER BY (CASE WHEN b.tier_pref = v_pref THEN 0 ELSE 0.7 END) + random()
      LIMIT 5
    LOOP
      v_slot := v_slot + 1;
      v_amt := CASE WHEN v_slot = 5 THEN v_left
                    ELSE public.club_commercial_round(v_total * v_weights[v_slot]) END;
      v_amt := greatest(0, least(v_amt, v_left));
      v_left := v_left - v_amt;

      v_ledger := public.club_commercial_post(
        p_club, 'commercial_advertising', v_amt,
        format('Pitchside advertising: %s', v_brand.name),
        jsonb_build_object('brand', v_brand.name, 'slot', v_slot),
        p_season
      );

      INSERT INTO public.club_commercial_boards (season_id, club_short_name, slot, brand_id, amount, ledger_id)
      VALUES (p_season, p_club, v_slot, v_brand.id, v_amt, v_ledger);
    END LOOP;
  END IF;

  -- Main sponsor
  v_contract := public.club_commercial_active_sponsorship(p_club, p_season);

  IF v_contract IS NOT NULL THEN
    PERFORM public.club_commercial_pay_sponsor_season(v_contract, p_season);
  ELSIF NOT EXISTS (
    SELECT 1 FROM public.club_commercial_sponsor_offers
    WHERE season_id = p_season AND club_short_name = p_club
  ) THEN
    v_long := public.club_commercial_round(v_value * s.long_deal_pct);
    v_short := v_value;
    v_base := public.club_commercial_round(v_value * s.perf_deal_base_pct);

    v_slot := 0;
    v_names := ARRAY[]::text[];
    FOR v_brand IN
      SELECT b.id, b.name
      FROM public.commercial_brands b
      WHERE b.active
        AND NOT EXISTS (
          SELECT 1 FROM public.club_commercial_sponsorships cs
          WHERE cs.brand_id = b.id
            AND cs.club_short_name <> p_club
            AND cs.start_season_id <= p_season
            AND public.club_commercial_season_offset(cs.start_season_id, p_season) < cs.seasons_total
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.club_commercial_sponsor_offers so
          WHERE so.brand_id = b.id
            AND so.season_id = p_season
            AND so.status = 'offered'
        )
      ORDER BY (CASE WHEN b.tier_pref = v_pref THEN 0 ELSE 0.7 END) + random()
      LIMIT 3
    LOOP
      v_slot := v_slot + 1;
      v_names := v_names || v_brand.name;
      INSERT INTO public.club_commercial_sponsor_offers (
        season_id, club_short_name, brand_id, deal_kind, seasons,
        amount_per_season, base_amount, max_amount, band_min, band_max, expires_at
      ) VALUES (
        p_season, p_club, v_brand.id,
        (ARRAY['long', 'short', 'performance'])[v_slot],
        CASE WHEN v_slot = 1 THEN 2 ELSE 1 END,
        CASE v_slot WHEN 1 THEN v_long WHEN 2 THEN v_short ELSE v_base END,
        CASE WHEN v_slot = 3 THEN v_base END,
        CASE WHEN v_slot = 3 THEN v_band[2] END,
        v_band[1], v_band[2],
        now() + make_interval(days => greatest(1, s.offer_days))
      );
    END LOOP;
    v_offers_made := v_slot > 0;

    IF v_offers_made AND v_owner IS NULL THEN
      SELECT id INTO v_expired_long
      FROM public.club_commercial_sponsor_offers
      WHERE season_id = p_season AND club_short_name = p_club AND status = 'offered'
      ORDER BY CASE deal_kind WHEN 'long' THEN 0 WHEN 'short' THEN 1 ELSE 2 END
      LIMIT 1;
      IF v_expired_long IS NOT NULL THEN
        PERFORM public.club_commercial_accept_internal(v_expired_long, true);
      END IF;
    ELSIF v_offers_made THEN
      DECLARE
        v_title text := '🤝 Sponsorship offers are in';
        v_body text := format(
          'Three companies want to be your main sponsor this season: %s. '
          'Long-term security, a bigger one-season payday, or a performance gamble? '
          'Choose on the Stadium page within %s days — otherwise the long-term deal is signed for you.',
          array_to_string(v_names, ', '), greatest(1, s.offer_days)
        );
        v_dedupe text := format('commercial_offer:%s:%s', p_season, p_club);
      BEGIN
        BEGIN
          PERFORM public.owner_inbox_send(
            'commercial_offer'::text, v_title, v_body, p_club, v_owner,
            NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
            'stadium.html#commercialPanel'::text, v_dedupe, NULL::text, p_season, NULL::bigint
          );
        EXCEPTION WHEN undefined_function THEN
          PERFORM public.owner_inbox_send(
            'commercial_offer'::text, v_title, v_body, p_club, v_owner,
            NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
            'stadium.html#commercialPanel'::text, v_dedupe, NULL::text, p_season
          );
        END;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'commercial offer inbox skipped for %: %', p_club, SQLERRM;
      END;
    END IF;
  ELSE
    -- Deadline passed with no choice → sign the safest (long) offer.
    SELECT id INTO v_expired_long
    FROM public.club_commercial_sponsor_offers
    WHERE season_id = p_season AND club_short_name = p_club
      AND status = 'offered' AND expires_at < now()
    ORDER BY CASE deal_kind WHEN 'long' THEN 0 WHEN 'short' THEN 1 ELSE 2 END
    LIMIT 1;
    IF v_expired_long IS NOT NULL THEN
      PERFORM public.club_commercial_accept_internal(v_expired_long, true);
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'club', p_club, 'tier', v_tier, 'score', v_score, 'offers_made', v_offers_made);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. Owner RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_commercial_accept_offer(p_offer_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  o public.club_commercial_sponsor_offers;
  v_contract bigint;
BEGIN
  SELECT * INTO o FROM public.club_commercial_sponsor_offers WHERE id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offer not found';
  END IF;

  IF NOT (
    public.is_gpsl_admin()
    OR EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE c."ShortName" = o.club_short_name AND c.owner_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'Only the club owner can choose a sponsor';
  END IF;

  IF o.status = 'offered' AND o.expires_at < now() THEN
    RAISE EXCEPTION 'The deadline for these offers has passed';
  END IF;

  v_contract := public.club_commercial_accept_internal(p_offer_id, false);
  RETURN jsonb_build_object('ok', true, 'sponsorship_id', v_contract);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_commercial_get_club(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  v_club text := btrim(p_club_short_name);
  v_season bigint;
  v_label text;
  v_tier text;
  v_band numeric[];
  v_can_decide boolean;
  v_contract bigint;
  v_sponsor jsonb;
  v_offers jsonb;
  v_boards jsonb;
  v_merch jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;
  v_season := public.club_commercial_current_season();
  SELECT label INTO v_label FROM public.competition_seasons WHERE id = v_season;

  v_can_decide := public.is_gpsl_admin() OR EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club AND c.owner_id = auth.uid()
  );

  IF v_can_decide AND v_season IS NOT NULL THEN
    PERFORM public.club_commercial_ensure_season(v_club, v_season);
  END IF;

  v_tier := public.club_commercial_tier(v_club);
  v_band := public.club_commercial_band(v_tier);
  v_contract := public.club_commercial_active_sponsorship(v_club, v_season);

  IF v_contract IS NOT NULL THEN
    SELECT jsonb_build_object(
      'id', c.id,
      'brand', b.name,
      'sector', b.sector,
      'tagline', b.tagline,
      'deal_kind', c.deal_kind,
      'seasons_total', c.seasons_total,
      'season_number', public.club_commercial_season_offset(c.start_season_id, v_season) + 1,
      'amount_per_season', c.amount_per_season,
      'base_amount', c.base_amount,
      'max_amount', c.max_amount,
      'auto_selected', c.auto_selected,
      'paid_this_season', coalesce((
        SELECT sum(p.amount) FROM public.club_commercial_sponsorship_payments p
        WHERE p.sponsorship_id = c.id AND p.season_id = v_season
      ), 0),
      'bonus_paid', EXISTS (
        SELECT 1 FROM public.club_commercial_sponsorship_payments p
        WHERE p.sponsorship_id = c.id AND p.season_id = v_season AND p.kind = 'performance_bonus'
      )
    )
    INTO v_sponsor
    FROM public.club_commercial_sponsorships c
    JOIN public.commercial_brands b ON b.id = c.brand_id
    WHERE c.id = v_contract;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id,
      'brand', b.name,
      'sector', b.sector,
      'tagline', b.tagline,
      'deal_kind', o.deal_kind,
      'seasons', o.seasons,
      'amount_per_season', o.amount_per_season,
      'base_amount', o.base_amount,
      'max_amount', o.max_amount,
      'band_min', o.band_min,
      'expires_at', o.expires_at
    ) ORDER BY CASE o.deal_kind WHEN 'long' THEN 0 WHEN 'short' THEN 1 ELSE 2 END), '[]'::jsonb)
  INTO v_offers
  FROM public.club_commercial_sponsor_offers o
  JOIN public.commercial_brands b ON b.id = o.brand_id
  WHERE o.season_id = v_season AND o.club_short_name = v_club AND o.status = 'offered';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'slot', bd.slot, 'brand', b.name, 'sector', b.sector, 'tagline', b.tagline, 'amount', bd.amount
    ) ORDER BY bd.slot), '[]'::jsonb)
  INTO v_boards
  FROM public.club_commercial_boards bd
  JOIN public.commercial_brands b ON b.id = bd.brand_id
  WHERE bd.season_id = v_season AND bd.club_short_name = v_club;

  SELECT jsonb_build_object(
      'shop', m.shop_amount, 'global', m.global_amount,
      'total', m.shop_amount + m.global_amount,
      'perf_score', m.perf_score, 'fill_score', m.fill_score
    )
  INTO v_merch
  FROM public.club_commercial_merch m
  WHERE m.season_id = v_season AND m.club_short_name = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', coalesce(s.enabled, false),
    'season_id', v_season,
    'season_label', v_label,
    'season_open', public.club_commercial_season_open(v_season),
    'in_season', public.club_commercial_in_season(v_club, v_season),
    'club', v_club,
    'tier', v_tier,
    'band_min', v_band[1],
    'band_max', v_band[2],
    'can_decide', v_can_decide,
    'sponsor', v_sponsor,
    'offers', v_offers,
    'boards', v_boards,
    'merch', v_merch
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 9. End of season: merchandising + performance-deal bonuses
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_post_commercial_eos(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  r record;
  c record;
  v_tier text;
  v_perf numeric;
  v_fill numeric;
  v_total numeric;
  v_shop numeric;
  v_global numeric;
  v_shop_id bigint;
  v_global_id bigint;
  v_target numeric;
  v_bonus numeric;
  v_pay_id bigint;
  v_ledger bigint;
  v_merch_n int := 0;
  v_bonus_n int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;
  IF NOT coalesce(s.enabled, false) OR p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  FOR r IN
    SELECT DISTINCT ccs.club_short_name AS club
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND ccs.club_short_name <> 'FOREIGN'
  LOOP
    v_tier := public.club_commercial_tier(r.club);
    v_perf := public.club_commercial_perf_score(r.club, p_season_id);

    -- Merchandising
    IF NOT EXISTS (
      SELECT 1 FROM public.club_commercial_merch
      WHERE season_id = p_season_id AND club_short_name = r.club
    ) THEN
      v_fill := public.club_commercial_fill_score(r.club, p_season_id);
      v_total := public.club_commercial_value(
        v_tier, (1 - s.merch_fill_weight) * v_perf + s.merch_fill_weight * v_fill
      );
      v_shop := public.club_commercial_round(v_total * s.shop_share);
      v_global := greatest(0, v_total - v_shop);

      v_shop_id := public.club_commercial_post(
        r.club, 'commercial_merchandise', v_shop,
        'Merchandising: club shop (kits & novelties)',
        jsonb_build_object('stream', 'shop', 'perf_score', v_perf, 'fill_score', v_fill),
        p_season_id
      );
      v_global_id := public.club_commercial_post(
        r.club, 'commercial_merchandise', v_global,
        'Merchandising: global kit sales',
        jsonb_build_object('stream', 'global', 'perf_score', v_perf, 'fill_score', v_fill),
        p_season_id
      );

      INSERT INTO public.club_commercial_merch (
        season_id, club_short_name, perf_score, fill_score,
        shop_amount, global_amount, shop_ledger_id, global_ledger_id
      ) VALUES (
        p_season_id, r.club, v_perf, v_fill, v_shop, v_global, v_shop_id, v_global_id
      );
      v_merch_n := v_merch_n + 1;
    END IF;

    -- Performance-deal bonus
    FOR c IN
      SELECT sp.*, b.name AS brand_name
      FROM public.club_commercial_sponsorships sp
      JOIN public.commercial_brands b ON b.id = sp.brand_id
      WHERE sp.club_short_name = r.club
        AND sp.deal_kind = 'performance'
        AND sp.start_season_id <= p_season_id
        AND public.club_commercial_season_offset(sp.start_season_id, p_season_id) < sp.seasons_total
    LOOP
      v_target := least(
        coalesce(c.max_amount, c.band_max),
        public.club_commercial_round(c.band_min + v_perf * (c.band_max - c.band_min))
      );
      v_bonus := greatest(0, v_target - coalesce(c.base_amount, 0));

      v_pay_id := NULL;
      INSERT INTO public.club_commercial_sponsorship_payments (sponsorship_id, season_id, kind, amount)
      VALUES (c.id, p_season_id, 'performance_bonus', v_bonus)
      ON CONFLICT (sponsorship_id, season_id, kind) DO NOTHING
      RETURNING id INTO v_pay_id;

      IF v_pay_id IS NOT NULL THEN
        v_ledger := public.club_commercial_post(
          r.club, 'commercial_sponsorship', v_bonus,
          format('Main sponsor performance bonus: %s', c.brand_name),
          jsonb_build_object('sponsorship_id', c.id, 'brand', c.brand_name, 'kind', 'performance_bonus', 'perf_score', v_perf),
          p_season_id
        );
        UPDATE public.club_commercial_sponsorship_payments SET ledger_id = v_ledger WHERE id = v_pay_id;
        v_bonus_n := v_bonus_n + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'merch_clubs', v_merch_n, 'performance_bonuses', v_bonus_n);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 10. Admin RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_club_commercial_run_season_start(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := coalesce(p_season_id, public.club_commercial_current_season());
  r record;
  v_res jsonb;
  v_ok int := 0;
  v_skipped int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF NOT public.club_commercial_season_open(v_season) THEN
    RAISE EXCEPTION 'Season % is not in setup / preseason / active', v_season;
  END IF;

  FOR r IN
    SELECT DISTINCT ccs.club_short_name AS club
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND ccs.club_short_name <> 'FOREIGN'
  LOOP
    v_res := public.club_commercial_ensure_season(r.club, v_season);
    IF coalesce((v_res->>'ok')::boolean, false) THEN
      v_ok := v_ok + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season, 'clubs', v_ok, 'skipped', v_skipped);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_commercial_overview(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := coalesce(p_season_id, public.club_commercial_current_season());
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.division, x.club), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      ccs.club_short_name AS club,
      cl."Club" AS club_name,
      ccs.division,
      (cl.owner_id IS NOT NULL) AS owned,
      public.club_commercial_tier(ccs.club_short_name) AS tier,
      sp.brand AS sponsor,
      sp.deal_kind,
      sp.auto_selected,
      coalesce(sp.paid, 0) AS sponsor_paid,
      (SELECT count(*) FROM public.club_commercial_sponsor_offers o
        WHERE o.season_id = v_season AND o.club_short_name = ccs.club_short_name
          AND o.status = 'offered') AS offers_pending,
      coalesce((SELECT sum(bd.amount) FROM public.club_commercial_boards bd
        WHERE bd.season_id = v_season AND bd.club_short_name = ccs.club_short_name), 0) AS boards_total,
      coalesce((SELECT m.shop_amount + m.global_amount FROM public.club_commercial_merch m
        WHERE m.season_id = v_season AND m.club_short_name = ccs.club_short_name), 0) AS merch_total
    FROM public.competition_club_seasons ccs
    LEFT JOIN public."Clubs" cl ON cl."ShortName" = ccs.club_short_name
    LEFT JOIN LATERAL (
      SELECT b.name AS brand, c.deal_kind, c.auto_selected,
        (SELECT sum(p.amount) FROM public.club_commercial_sponsorship_payments p
          WHERE p.sponsorship_id = c.id AND p.season_id = v_season) AS paid
      FROM public.club_commercial_sponsorships c
      JOIN public.commercial_brands b ON b.id = c.brand_id
      WHERE c.id = public.club_commercial_active_sponsorship(ccs.club_short_name, v_season)
    ) sp ON true
    WHERE ccs.season_id = v_season
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND ccs.club_short_name <> 'FOREIGN'
  ) x;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season, 'rows', v_rows);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_commercial_post_eos(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_post_commercial_eos(
    coalesce(p_season_id, public.club_commercial_current_season())
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 11. Close Finances: run commercial EOS after maintenance, before debt interest
-- ---------------------------------------------------------------------------
DO $close_fin$
DECLARE
  v_def text;
  v_anchor text := 'v_debt := public.competition_post_eos_debt_interest(v_season_id);';
BEGIN
  SELECT pg_get_functiondef('public.competition_admin_close_finances(bigint)'::regprocedure)
  INTO v_def;

  IF v_def LIKE '%competition_post_commercial_eos%' THEN
    RETURN;
  END IF;

  IF position(v_anchor IN v_def) = 0 THEN
    RAISE NOTICE 'Close Finances anchor not found — run Admin → Commercial income → "Post end-of-season" manually before Close Finances.';
    RETURN;
  END IF;

  v_def := replace(
    v_def,
    v_anchor,
    'IF to_regprocedure(''public.competition_post_commercial_eos(bigint)'') IS NOT NULL THEN
    PERFORM public.competition_post_commercial_eos(v_season_id);
  END IF;

  ' || v_anchor
  );
  EXECUTE v_def;
END;
$close_fin$;

GRANT EXECUTE ON FUNCTION public.club_commercial_get_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_commercial_accept_offer(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_commercial_run_season_start(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_commercial_overview(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_commercial_post_eos(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_commercial_eos(bigint) TO authenticated;

-- Internal helpers: not callable from the API
REVOKE EXECUTE ON FUNCTION public.club_commercial_post(text, text, numeric, text, jsonb, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.club_commercial_pay_sponsor_season(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.club_commercial_accept_internal(bigint, boolean) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.club_commercial_ensure_season(text, bigint) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
