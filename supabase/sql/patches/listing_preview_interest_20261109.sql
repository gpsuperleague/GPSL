-- =============================================================================
-- Preview listing interest — transfer market only
--
-- On a Pending Window listing, another club can declare interest.
-- The market shows that club's badge beside the player.
-- The selling club cannot tick its own listing.
-- Interest is removed when the listing leaves Pending Window.
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.listing_preview_interest (
  listing_id bigint NOT NULL
    REFERENCES public."Player_Transfer_Listings" (id) ON DELETE CASCADE,
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON UPDATE CASCADE ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (listing_id, club_short_name)
);

CREATE INDEX IF NOT EXISTS listing_preview_interest_club_idx
  ON public.listing_preview_interest (club_short_name);

COMMENT ON TABLE public.listing_preview_interest IS
  'Clubs that declared interest on a Pending Window (preview) listing. Shown as badges on the transfer market.';

ALTER TABLE public.listing_preview_interest ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS listing_preview_interest_read ON public.listing_preview_interest;
CREATE POLICY listing_preview_interest_read
  ON public.listing_preview_interest
  FOR SELECT
  TO authenticated
  USING (true);

GRANT SELECT ON public.listing_preview_interest TO authenticated;

CREATE OR REPLACE FUNCTION public.listing_preview_interest_set(
  p_listing_id bigint,
  p_interested boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_seller text;
  v_status text;
  v_type text;
  v_new int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club';
  END IF;
  IF p_listing_id IS NULL THEN
    RAISE EXCEPTION 'Listing required';
  END IF;

  SELECT
    upper(btrim(l.seller_club_id)),
    l.status,
    lower(coalesce(l.listing_type::text, ''))
  INTO v_seller, v_status, v_type
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = p_listing_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found';
  END IF;
  IF v_type = 'draft' OR v_status IS DISTINCT FROM 'Pending Window' THEN
    RAISE EXCEPTION 'Interest is only for a preview listing';
  END IF;
  IF v_seller = v_club THEN
    RAISE EXCEPTION 'You cannot declare interest in your own player';
  END IF;

  IF coalesce(p_interested, false) THEN
    INSERT INTO public.listing_preview_interest (listing_id, club_short_name)
    VALUES (p_listing_id, v_club)
    ON CONFLICT (listing_id, club_short_name) DO NOTHING;
    GET DIAGNOSTICS v_new = ROW_COUNT;
    IF v_new = 1 THEN
      BEGIN
        PERFORM public.gpsl_preview_interest_post_gossip(p_listing_id, v_club);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'preview interest gossip: %', SQLERRM;
      END;
    END IF;
  ELSE
    DELETE FROM public.listing_preview_interest
    WHERE listing_id = p_listing_id
      AND club_short_name = v_club;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', p_listing_id,
    'club', v_club,
    'interested', coalesce(p_interested, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.listing_preview_interest_set(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.listing_preview_interest_set(bigint, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.trg_listing_preview_interest_clear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF OLD.status = 'Pending Window'
     AND NEW.status IS DISTINCT FROM 'Pending Window' THEN
    DELETE FROM public.listing_preview_interest
    WHERE listing_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_listing_preview_interest_clear
  ON public."Player_Transfer_Listings";

CREATE TRIGGER trg_listing_preview_interest_clear
  AFTER UPDATE OF status ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_listing_preview_interest_clear();

NOTIFY pgrst, 'reload schema';
