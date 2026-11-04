-- =============================================================================
-- Sale interest notify:
--   • Manual: seller notifies clubs that scout a player ("thinking of listing")
--   • Auto: on new Active / Pending Window listing, inbox those scout clubs
-- Safe re-run.
-- =============================================================================

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
    SELECT unnest(ARRAY[
      'transfer_prelist_interest',
      'transfer_listed_interest'
    ])
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

CREATE OR REPLACE FUNCTION public.club_player_sale_interest_clubs(
  p_seller_club text,
  p_player_id text
)
RETURNS TABLE (
  club_short_name text,
  club_name text,
  owner_id uuid,
  owner_tag text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_seller text := upper(nullif(btrim(coalesce(p_seller_club, '')), ''));
  v_pid text := btrim(coalesce(p_player_id, ''));
BEGIN
  IF v_seller IS NULL OR v_pid = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (c."ShortName")
    c."ShortName"::text,
    coalesce(nullif(btrim(c."Club"), ''), c."ShortName")::text,
    c.owner_id,
    coalesce(
      nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
      nullif(btrim(c.owner), ''),
      '—'
    )::text
  FROM public.owner_scouting_targets t
  JOIN public."Clubs" c
    ON c.owner_id = t.owner_id
   AND c."ShortName" IS DISTINCT FROM v_seller
  JOIN public."Players" p
    ON p."Konami_ID"::text = t.player_id::text
   AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_seller
  WHERE t.player_id::text = v_pid
  ORDER BY c."ShortName", coalesce(t.is_active_target, false) DESC, t.tier ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_player_sale_interest_send_inbox(
  p_message_type text,
  p_title text,
  p_body text,
  p_recipient_club text,
  p_owner_id uuid,
  p_href text,
  p_dedupe text,
  p_listing_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  BEGIN
    v_id := public.owner_inbox_send(
      p_message_type, p_title, p_body, p_recipient_club, p_owner_id,
      NULL::bigint, NULL::bigint, NULL::bigint, p_listing_id,
      p_href, p_dedupe, NULL::text, NULL::bigint, NULL::bigint
    );
  EXCEPTION WHEN undefined_function THEN
    v_id := public.owner_inbox_send(
      p_message_type, p_title, p_body, p_recipient_club, p_owner_id,
      NULL::bigint, NULL::bigint, NULL::bigint, p_listing_id,
      p_href, p_dedupe, NULL::text, NULL::bigint
    );
  END;
  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'sale interest inbox skipped (% → %): %', p_message_type, p_recipient_club, SQLERRM;
  RETURN NULL;
END;
$function$;

-- Manual: "thinking of listing — interested?"
CREATE OR REPLACE FUNCTION public.club_player_sale_notify_interested(
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_name text;
  v_pos text;
  v_rating text;
  v_seller_name text;
  v_seller_tag text;
  v_body text;
  v_title text;
  v_sent int := 0;
  v_skipped int := 0;
  r record;
  v_inbox bigint;
  v_day text := to_char(timezone('utc', now()), 'YYYY-MM-DD');
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;
  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  SELECT
    p."Name",
    p."Position",
    p."Rating"::text,
    coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
    coalesce(
      nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
      nullif(btrim(c.owner), ''),
      '—'
    )
  INTO v_name, v_pos, v_rating, v_seller_name, v_seller_tag
  FROM public."Players" p
  JOIN public."Clubs" c ON c."ShortName" = v_club
  WHERE p."Konami_ID"::text = v_pid
    AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_your_player');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.club_player_sale_marks m
    WHERE m.club_short_name = v_club AND m.player_id = v_pid
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_marked',
      'detail', 'Mark the player for sale first, then notify interested clubs.'
    );
  END IF;

  v_title := format('Thinking of listing %s', coalesce(v_name, v_pid));
  v_body := format(
    E'%s (%s) is considering listing %s (%s · OVR %s) in an upcoming transfer window.\n\n'
    || E'You have them on your scouting shortlist — would you be interested?\n'
    || E'Reply via Natter / Discord, or watch Transfer Centre when they list.',
    coalesce(v_seller_name, v_club),
    coalesce(v_seller_tag, '—'),
    coalesce(v_name, v_pid),
    coalesce(nullif(btrim(v_pos), ''), '?'),
    coalesce(nullif(btrim(v_rating), ''), '—')
  );

  FOR r IN
    SELECT * FROM public.club_player_sale_interest_clubs(v_club, v_pid)
  LOOP
    v_inbox := public.club_player_sale_interest_send_inbox(
      'transfer_prelist_interest',
      v_title,
      v_body,
      r.club_short_name,
      r.owner_id,
      'transfer_center.html',
      format('prelist_interest:%s:%s:%s:%s', v_club, v_pid, r.club_short_name, v_day),
      NULL
    );
    IF v_inbox IS NOT NULL THEN
      v_sent := v_sent + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  IF v_sent = 0 AND v_skipped = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_interest',
      'detail', 'No other clubs currently have this player on their scouting shortlist.'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_name,
    'sent', v_sent,
    'skipped', v_skipped,
    'detail', format('Notified %s club(s). Already-notified today are skipped.', v_sent)
  );
END;
$function$;

-- Auto: listing created → notify scout clubs
CREATE OR REPLACE FUNCTION public.club_player_sale_notify_listed(
  p_seller_club text,
  p_player_id text,
  p_listing_id bigint,
  p_status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_seller_club, '')), ''));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_status text := coalesce(nullif(btrim(p_status), ''), 'Active');
  v_name text;
  v_pos text;
  v_rating text;
  v_seller_name text;
  v_body text;
  v_title text;
  v_sent int := 0;
  v_skipped int := 0;
  r record;
  v_inbox bigint;
  v_status_line text;
BEGIN
  IF v_club IS NULL OR v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_args');
  END IF;

  SELECT
    p."Name",
    p."Position",
    p."Rating"::text,
    coalesce(nullif(btrim(c."Club"), ''), c."ShortName")
  INTO v_name, v_pos, v_rating, v_seller_name
  FROM public."Players" p
  JOIN public."Clubs" c ON c."ShortName" = v_club
  WHERE p."Konami_ID"::text = v_pid;

  v_status_line := CASE
    WHEN lower(v_status) LIKE '%pending%' THEN 'listed for the next transfer window (Pending Window)'
    ELSE 'now Active on the transfer list'
  END;

  v_title := format('Listed: %s', coalesce(v_name, v_pid));
  v_body := format(
    E'%s (%s · OVR %s) from %s is %s.\n\n'
    || E'You had them on your scouting shortlist — open Transfer Centre / listings to follow the auction.',
    coalesce(v_name, v_pid),
    coalesce(nullif(btrim(v_pos), ''), '?'),
    coalesce(nullif(btrim(v_rating), ''), '—'),
    coalesce(v_seller_name, v_club),
    v_status_line
  );

  FOR r IN
    SELECT * FROM public.club_player_sale_interest_clubs(v_club, v_pid)
  LOOP
    v_inbox := public.club_player_sale_interest_send_inbox(
      'transfer_listed_interest',
      v_title,
      v_body,
      r.club_short_name,
      r.owner_id,
      CASE
        WHEN p_listing_id IS NOT NULL
          THEN format('all_listings.html?focus=%s', p_listing_id)
        ELSE 'all_listings.html'
      END,
      format(
        'listed_interest:%s:%s',
        coalesce(p_listing_id::text, v_pid),
        r.club_short_name
      ),
      p_listing_id
    );
    IF v_inbox IS NOT NULL THEN
      v_sent := v_sent + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'sent', v_sent,
    'skipped', v_skipped,
    'listing_id', p_listing_id,
    'player_id', v_pid
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_listing_notify_sale_interest()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'INSERT'
     AND NEW.status IN ('Active', 'Pending Window')
     AND nullif(btrim(coalesce(NEW.player_id::text, '')), '') IS NOT NULL
     AND nullif(btrim(coalesce(NEW.seller_club_id::text, '')), '') IS NOT NULL
  THEN
    PERFORM public.club_player_sale_notify_listed(
      NEW.seller_club_id::text,
      NEW.player_id::text,
      NEW.id,
      NEW.status::text
    );
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trg_listing_notify_sale_interest: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_listing_notify_sale_interest ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_listing_notify_sale_interest
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_listing_notify_sale_interest();

REVOKE ALL ON FUNCTION public.club_player_sale_interest_clubs(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.club_player_sale_interest_send_inbox(text, text, text, text, uuid, text, text, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.club_player_sale_notify_interested(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.club_player_sale_notify_listed(text, text, bigint, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.club_player_sale_interest_clubs(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_player_sale_notify_interested(text) TO authenticated;
-- listed notify is trigger/service path; keep executable for admins/tests
GRANT EXECUTE ON FUNCTION public.club_player_sale_notify_listed(text, text, bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
