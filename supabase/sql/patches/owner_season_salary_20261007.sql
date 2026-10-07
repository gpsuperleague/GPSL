-- =============================================================================
-- Owner season salary (Building Society credits)
--
--   • 100 credits per 1,000 stadium seats (pro-rata), paid at season end.
--   • Only paid when the club met its season expectation (league on target,
--     or a slight league miss rescued by a cup target).
--   • Paid AFTER the board fine, inside the same season-end club loop
--     (club_underperformance_process_season), so the fine never takes a cut.
--   • One payment per club per season — safe to re-run.
--
-- Rate: global_settings.owner_salary_per_1000_seats (default 100).
-- Safe to re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS owner_salary_per_1000_seats numeric NOT NULL DEFAULT 100;

CREATE OR REPLACE FUNCTION public.owner_season_salary_amount(p_club_short_name text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT round(
    greatest(coalesce(c."Capacity", 0), 0)::numeric / 1000
      * coalesce((SELECT g.owner_salary_per_1000_seats FROM public.global_settings g WHERE g.id = 1), 100)
  )
  FROM public."Clubs" c
  WHERE c."ShortName" = btrim(p_club_short_name);
$$;

CREATE OR REPLACE FUNCTION public.owner_season_salary_pay(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_owner uuid;
  v_capacity int;
  v_amount numeric;
  v_ledger bigint;
  v_season_label text;
BEGIN
  IF v_club IS NULL OR v_club = '' OR p_season_id IS NULL THEN
    RETURN jsonb_build_object('paid', false, 'reason', 'missing_input');
  END IF;

  SELECT c.owner_id, coalesce(c."Capacity", 0)::int
  INTO v_owner, v_capacity
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('paid', false, 'reason', 'no_owner');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.owner_finance_ledger l
    WHERE l.entry_type = 'owner_season_salary'
      AND l.season_id = p_season_id
      AND l.metadata->>'club' = v_club
  ) THEN
    RETURN jsonb_build_object('paid', false, 'reason', 'already_paid');
  END IF;

  v_amount := coalesce(public.owner_season_salary_amount(v_club), 0);
  SELECT label INTO v_season_label FROM public.competition_seasons WHERE id = p_season_id;

  IF public.club_expectation_missed_for_season(v_club, p_season_id) THEN
    BEGIN
      PERFORM public.owner_inbox_send(
        p_message_type => 'season_overview',
        p_title => 'Owner salary withheld',
        p_body => format(
          'The club missed its season expectation, so the board has withheld your owner salary of ₿%s (%s seats × ₿%s per 1,000). Meet the expectation next season to be paid.',
          to_char(v_amount, 'FM999,999,999'),
          to_char(v_capacity, 'FM999,999,999'),
          to_char(coalesce((SELECT g.owner_salary_per_1000_seats FROM public.global_settings g WHERE g.id = 1), 100), 'FM999,999')
        ),
        p_recipient_club => v_club,
        p_action_href => 'season_review.html',
        p_dedupe_key => format('owner_salary:%s:%s', v_club, p_season_id),
        p_season_id => p_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    RETURN jsonb_build_object('paid', false, 'reason', 'expectation_missed', 'amount', v_amount);
  END IF;

  IF v_amount <= 0 THEN
    RETURN jsonb_build_object('paid', false, 'reason', 'no_capacity');
  END IF;

  v_ledger := public._post_owner_ledger_internal(
    v_owner,
    'owner_season_salary',
    v_amount,
    format('Owner salary — %s (%s seats)', coalesce(v_season_label, 'season'), to_char(v_capacity, 'FM999,999,999')),
    jsonb_build_object('club', v_club, 'capacity', v_capacity, 'source', 'season_end'),
    p_season_id,
    true
  );

  BEGIN
    PERFORM public.owner_inbox_send(
      p_message_type => 'season_overview',
      p_title => 'Owner salary paid',
      p_body => format(
        'The club met its season expectation — the board has paid your owner salary of ₿%s (%s seats) into your Building Society wallet.',
        to_char(v_amount, 'FM999,999,999'),
        to_char(v_capacity, 'FM999,999,999')
      ),
      p_recipient_club => v_club,
      p_action_href => 'season_review.html',
      p_dedupe_key => format('owner_salary:%s:%s', v_club, p_season_id),
      p_season_id => p_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('paid', true, 'amount', v_amount, 'ledger_id', v_ledger);
END;
$function$;

-- Season-end club loop: board fine / transfer request first, then salary.
CREATE OR REPLACE FUNCTION public.club_underperformance_process_season(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_salary jsonb;
  v_triggered int := 0;
BEGIN
  IF p_season_id IS NULL THEN
    RAISE EXCEPTION 'season_id is required';
  END IF;

  FOR v_club IN
    SELECT c."ShortName" AS club_short_name
    FROM public."Clubs" c
    WHERE c."ShortName" <> 'FOREIGN'
      AND c.owner_id IS NOT NULL
    ORDER BY c."ShortName"
  LOOP
    v_row := public.club_underperformance_process_club(v_club.club_short_name, p_season_id);

    BEGIN
      v_salary := public.owner_season_salary_pay(v_club.club_short_name, p_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_salary := jsonb_build_object('paid', false, 'reason', 'error', 'error', SQLERRM);
    END;

    v_results := v_results || jsonb_build_array(coalesce(v_row, '{}'::jsonb) || jsonb_build_object('owner_salary', v_salary));

    IF v_row ? 'listing_id' THEN
      v_triggered := v_triggered + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'triggered_count', v_triggered,
    'results', v_results
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_season_salary_pay(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_season_salary_amount(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Preview: what each owned club would get
SELECT
  c."ShortName" AS club,
  coalesce(c."Capacity", 0) AS capacity,
  public.owner_season_salary_amount(c."ShortName") AS salary_if_on_target
FROM public."Clubs" c
WHERE c.owner_id IS NOT NULL
  AND c."ShortName" <> 'FOREIGN'
ORDER BY capacity DESC;
