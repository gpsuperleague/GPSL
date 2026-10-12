-- =============================================================================
-- Club takeover mid-season: new owner inherits the club as it stands
--
-- Bug (Marseille, 12 Oct): BokirCa won MAR at auction (stadium + premium
-- charged, starting budget set), left, and croroshi was linked by admin.
-- Because the stadium-paid check only looked for *this owner's* purchase,
-- the takeover charged the stadium again and reset the balance to a fresh
-- starting budget — wiping the One of our Own draw cost, advertising income
-- and tax that had already been posted.
--
-- Fix:
--   1) club_has_assignment_infra_purchase: stadium counts as paid if the club
--      has ever had an assignment / auction stadium purchase, by any owner.
--      Vacating a club never touches its balance or ledger, so the next owner
--      simply takes over squad, manager, balance and ledger. Applies to admin
--      link, waiting list and club auction (all go through
--      owner_apply_club_assignment_finances).
--   2) Welcome inbox is per owner, not per club, so a new owner of a club gets
--      their own welcome (backfill still honours the old per-club key).
--   3) Repair every club with a second assignment stadium charge this season:
--      delete the duplicate row and restore the balance to what it would have
--      been without the reset (everything posted since — e.g. MAR's manager
--      signing — is kept). Logged in club_takeover_finance_repair_log.
--   4) Send the missed welcome to current owners of repaired clubs.
-- Safe re-run.
-- =============================================================================

-- 1) Stadium paid once per club (any owner)
CREATE OR REPLACE FUNCTION public.club_has_assignment_infra_purchase(
  p_club_short_name text,
  p_owner_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF v_club = '' THEN
    RETURN false;
  END IF;

  IF public.club_had_prior_finance_season(v_club, public.competition_finances_current_season_id()) THEN
    RETURN true;
  END IF;

  -- p_owner_id kept for callers; a takeover inherits the previous owner's purchase
  RETURN EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = 'infra_purchase'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_has_assignment_infra_purchase(text, uuid) TO authenticated;

-- 2) Welcome per owner + club
CREATE OR REPLACE FUNCTION public.owner_inbox_send_welcome(
  p_owner_id uuid,
  p_club_short_name text DEFAULT NULL,
  p_created_at timestamptz DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(trim(coalesce(p_club_short_name, '')));
  v_club_name text;
  v_body text;
  v_id bigint;
  v_dedupe text;
BEGIN
  IF v_club <> '' THEN
    SELECT c."Club" INTO v_club_name
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;

    v_body := format(
      E'Welcome to GPSL — you are now linked to %s.\n\nRead Learning GPSL for navigation, auctions, contracts, matchday, and club expectations.',
      coalesce(v_club_name, v_club)
    );
    v_dedupe := 'welcome:' || v_club || ':' || coalesce(p_owner_id::text, '');

    IF EXISTS (SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = v_dedupe) THEN
      RETURN NULL;
    END IF;

    -- Backfills (backdated) treat the old one-per-club key as already sent
    IF p_created_at IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = 'welcome:' || v_club) THEN
      RETURN NULL;
    END IF;

    INSERT INTO public.competition_inbox (
      recipient_club_short_name, owner_id, message_type,
      title, body, action_href, dedupe_key, created_at
    )
    VALUES (
      v_club, NULL, 'welcome_gpsl', 'Welcome to GPSL',
      v_body, 'learning_gpsl.html', v_dedupe, coalesce(p_created_at, now())
    )
    RETURNING id INTO v_id;

    RETURN v_id;
  END IF;

  v_body := E'Welcome to GPSL.\n\nYou are registered for the club auction. Read Learning GPSL while you wait — it covers navigation, auctions, contracts, and what is expected of owners.';
  v_dedupe := 'welcome:owner:' || p_owner_id::text;

  IF EXISTS (SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = v_dedupe) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    title, body, action_href, dedupe_key, created_at
  )
  VALUES (
    NULL, p_owner_id, 'welcome_gpsl', 'Welcome to GPSL',
    v_body, 'learning_gpsl.html', v_dedupe, coalesce(p_created_at, now())
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- 3) Repair duplicate takeover stadium charges this season
CREATE TABLE IF NOT EXISTS public.club_takeover_finance_repair_log (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL,
  removed_ledger_id bigint NOT NULL UNIQUE,
  removed_amount numeric NOT NULL,
  balance_before numeric,
  balance_after numeric,
  note text,
  repaired_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.club_takeover_finance_repair_log ENABLE ROW LEVEL SECURITY;

DO $repair$
DECLARE
  v_season bigint := public.competition_finances_current_season_id();
  d record;
  v_between numeric;
  v_pre numeric;
  v_post numeric;
  v_bal numeric;
  v_new numeric;
  v_note text;
BEGIN
  FOR d IN
    SELECT dup.id AS dup_id, dup.club_short_name AS club, dup.amount AS dup_amount,
           (dup.metadata->>'starting_budget')::numeric AS dup_start,
           first.id AS first_id, first.amount AS first_amount,
           (first.metadata->>'starting_budget')::numeric AS first_start
    FROM public.competition_finance_ledger dup
    JOIN LATERAL (
      SELECT f.*
      FROM public.competition_finance_ledger f
      WHERE f.club_short_name = dup.club_short_name
        AND f.entry_type = 'infra_purchase'
        AND f.season_id = dup.season_id
        AND f.id < dup.id
        AND coalesce(f.metadata->>'source', '') IN ('club_assignment', 'club_auction', 'assignment', 'admin_assign')
      ORDER BY f.id
      LIMIT 1
    ) first ON true
    WHERE dup.entry_type = 'infra_purchase'
      AND dup.season_id = v_season
      AND coalesce(dup.metadata->>'source', '') IN ('club_assignment', 'club_auction', 'assignment', 'admin_assign')
      AND coalesce(dup.metadata->>'owner_id', '') IS DISTINCT FROM coalesce(first.metadata->>'owner_id', '')
      AND NOT EXISTS (
        SELECT 1 FROM public.club_takeover_finance_repair_log g WHERE g.removed_ledger_id = dup.id
      )
    ORDER BY dup.id
  LOOP
    SELECT balance INTO v_bal FROM public."Club_Finances" WHERE club_name = d.club;

    IF d.first_start IS NULL OR d.dup_start IS NULL OR v_bal IS NULL THEN
      v_new := v_bal;
      v_note := 'Duplicate stadium row removed; balance NOT changed (starting budget missing on ledger metadata) — check manually';
    ELSE
      -- Everything posted between the original purchase and the takeover
      SELECT coalesce(sum(l.amount), 0) INTO v_between
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = d.club
        AND l.id > d.first_id
        AND l.id < d.dup_id;

      v_pre := d.first_start - abs(d.first_amount) + v_between;   -- balance just before takeover
      v_post := greatest(d.dup_start - abs(d.dup_amount), 0);     -- balance the takeover reset it to
      v_new := v_bal - v_post + v_pre;
      v_note := format('pre-takeover %s, reset to %s, now %s → %s', v_pre, v_post, v_bal, v_new);

      UPDATE public."Club_Finances" SET balance = v_new WHERE club_name = d.club;
    END IF;

    DELETE FROM public.competition_finance_ledger WHERE id = d.dup_id;

    INSERT INTO public.club_takeover_finance_repair_log
      (club_short_name, removed_ledger_id, removed_amount, balance_before, balance_after, note)
    VALUES (d.club, d.dup_id, d.dup_amount, v_bal, v_new, v_note);

    RAISE NOTICE 'Repaired %: %', d.club, v_note;
  END LOOP;
END
$repair$;

-- 4) Missed welcome for current owners of repaired clubs
SELECT public.owner_inbox_send_welcome(c.owner_id, c."ShortName", NULL::timestamptz)
FROM public."Clubs" c
WHERE c.owner_id IS NOT NULL
  AND c."ShortName" IN (SELECT club_short_name FROM public.club_takeover_finance_repair_log);

NOTIFY pgrst, 'reload schema';

-- Report
SELECT g.club_short_name, g.removed_ledger_id, g.removed_amount,
       g.balance_before, g.balance_after,
       (SELECT balance FROM public."Club_Finances" WHERE club_name = g.club_short_name) AS balance_now,
       g.note, g.repaired_at
FROM public.club_takeover_finance_repair_log g
ORDER BY g.repaired_at DESC;
