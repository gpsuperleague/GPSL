-- =============================================================================
-- Main sponsor choice resets when a club changes owner before June locks
--
-- The three main-sponsor offers (long / one-season / performance) belong to
-- the owner who runs the club in June. If a club changes hands before GPSL
-- June locks, the new owner gets a fresh choice:
--   • a deal signed this season by the previous owner (or auto-signed) is
--     reversed — up-front payment taken back, Central Bank refunded, contract
--     removed
--   • old offers are cleared and three new offers are made, open until June
--     locks, with the "Sponsorship offers are in" inbox to the new owner
-- Pitchside boards are not touched (automatic income, not an owner choice).
-- Multi-season deals signed in an earlier season stay with the club.
--
-- Runs automatically on every owner change (admin link, waiting list, club
-- auction) and once now for Marseille. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_commercial_reset_for_new_owner(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_season bigint := public.club_commercial_current_season();
  v_june_lock timestamptz;
  r record;
  p record;
  v_id bigint;
  v_reversed numeric := 0;
  v_offers int := 0;
  v_ensure jsonb;
BEGIN
  IF v_club = '' OR v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club_or_season');
  END IF;

  SELECT m.lock_at INTO v_june_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season AND m.gpsl_month = 'june';

  IF v_june_lock IS NULL OR v_june_lock <= now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'june_locked', 'june_lock', v_june_lock);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('club_commercial:' || v_club || ':' || v_season));

  -- Deal signed this season → reverse
  FOR r IN
    SELECT cs.* FROM public.club_commercial_sponsorships cs
    WHERE cs.club_short_name = v_club AND cs.start_season_id = v_season
  LOOP
    FOR p IN
      SELECT sp.* FROM public.club_commercial_sponsorship_payments sp
      WHERE sp.sponsorship_id = r.id
    LOOP
      IF coalesce(p.amount, 0) > 0 THEN
        v_id := public.post_club_ledger(
          v_club, 'commercial_sponsorship', -p.amount,
          'Main sponsor reversed — new owner chooses their own sponsor',
          jsonb_build_object('sponsorship_id', r.id, 'reverses_payment_id', p.id, 'kind', 'new_owner_reset'),
          v_season, NULL, true, true
        );
        IF v_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_id) THEN
          UPDATE public.gpsl_bank_account SET reserves = reserves + p.amount, updated_at = now() WHERE id = 1;
          INSERT INTO public.bank_ledger (entry_type, amount, description, club_short_name, club_ledger_id, metadata)
          VALUES ('commercial_sponsorship', p.amount, 'Main sponsor reversed (new owner)', v_club, v_id,
                  jsonb_build_object('sponsorship_id', r.id, 'kind', 'new_owner_reset'));
        END IF;
        v_reversed := v_reversed + p.amount;
      END IF;
    END LOOP;

    DELETE FROM public.club_commercial_sponsorship_payments WHERE sponsorship_id = r.id;
    DELETE FROM public.club_commercial_sponsorships WHERE id = r.id;
  END LOOP;

  -- Clear old offers + the previous owner's offer inbox (its dedupe key would block the new one)
  DELETE FROM public.club_commercial_sponsor_offers
  WHERE season_id = v_season AND club_short_name = v_club;
  GET DIAGNOSTICS v_offers = ROW_COUNT;

  DELETE FROM public.competition_inbox
  WHERE dedupe_key IN (
    format('commercial_offer:%s:%s', v_season, v_club),
    format('commercial_topup:%s:%s', v_season, v_club),
    format('commercial_reopen:%s:%s', v_season, v_club)
  );

  -- Fresh offers + inbox for the current owner (vacant clubs get none)
  v_ensure := public.club_commercial_ensure_season(v_club, v_season);

  RETURN jsonb_build_object(
    'ok', true, 'club', v_club, 'season_id', v_season,
    'sponsor_payment_reversed', v_reversed,
    'old_offers_cleared', v_offers,
    'ensure', v_ensure,
    'choose_by', v_june_lock
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.club_commercial_reset_for_new_owner(text) FROM PUBLIC, anon, authenticated;

-- Every owner change (club had a previous owner, or offers already exist)
CREATE OR REPLACE FUNCTION public.trg_clubs_owner_change_commercial_reset()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.owner_id IS NOT NULL
     AND NEW.owner_id IS DISTINCT FROM OLD.owner_id
     AND to_regprocedure('public.club_commercial_current_season()') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.club_commercial_sponsor_offers o
       WHERE o.club_short_name = NEW."ShortName"
         AND o.season_id = public.club_commercial_current_season()
     ) THEN
    BEGIN
      PERFORM public.club_commercial_reset_for_new_owner(NEW."ShortName");
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Sponsor reset for new owner failed for %: %', NEW."ShortName", SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_owner_change_commercial_reset ON public."Clubs";
CREATE TRIGGER clubs_owner_change_commercial_reset
AFTER UPDATE OF owner_id ON public."Clubs"
FOR EACH ROW
EXECUTE FUNCTION public.trg_clubs_owner_change_commercial_reset();

-- Marseille now
SELECT public.club_commercial_reset_for_new_owner('MAR') AS marseille_reset;

NOTIFY pgrst, 'reload schema';

-- Report: Marseille's sponsor offers now
SELECT o.deal_kind, b.name AS brand, o.amount_per_season, o.base_amount, o.max_amount,
       o.status, o.expires_at AT TIME ZONE 'Europe/London' AS choose_by_uk
FROM public.club_commercial_sponsor_offers o
JOIN public.commercial_brands b ON b.id = o.brand_id
WHERE o.club_short_name = 'MAR'
  AND o.season_id = public.club_commercial_current_season()
ORDER BY o.deal_kind;
