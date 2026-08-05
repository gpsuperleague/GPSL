-- =============================================================================
-- Manager renewal deadline: renew by August or release for market value
--
-- After a successful 2-season deal (pending_owner_renewal), the owner may renew
-- in June / July / August of the following season. When August ends (month lock)
-- — or if still pending later — the manager is released for full market value.
-- No rehire ban (unlike failed-target releases).
--
-- Safe re-run.
-- =============================================================================

-- Clear pending flag on any release so FA rows stay clean
CREATE OR REPLACE FUNCTION public.manager_release_from_club(
  p_manager_id bigint,
  p_payout_club text DEFAULT NULL,
  p_payout_amount numeric DEFAULT NULL,
  p_ledger_type text DEFAULT 'transfer_sale',
  p_description text DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_club text;
  v_payout numeric;
  v_desc text;
  v_meta jsonb;
  v_end_kind text := 'release';
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  v_club := v_mgr.contracted_club;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'Manager is a free agent';
  END IF;

  v_payout := coalesce(p_payout_amount, v_mgr.market_value::numeric);
  v_desc := coalesce(nullif(btrim(p_description), ''), format('Manager release — %s', v_mgr.name));
  v_meta := coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager');

  IF p_payout_club IS NOT NULL AND v_payout > 0 THEN
    PERFORM public.post_club_ledger(
      p_payout_club,
      p_ledger_type,
      abs(v_payout),
      v_desc,
      v_meta
    );
  END IF;

  IF coalesce((p_metadata->>'manager_sack')::boolean, false)
    OR coalesce(p_metadata->>'manager_sack', '') IN ('true', 't', '1')
    OR v_desc ILIKE 'Manager sack%' THEN
    v_end_kind := 'sack';
  ELSIF p_ledger_type = 'transfer_sale' THEN
    v_end_kind := 'transfer';
  END IF;

  IF to_regprocedure('public.manager_stint_close(bigint,text,numeric,text,timestamptz)') IS NOT NULL THEN
    PERFORM public.manager_stint_close(
      p_manager_id,
      v_club,
      CASE WHEN v_end_kind = 'sack' THEN v_payout ELSE NULL END,
      v_end_kind,
      now()
    );
  END IF;

  UPDATE public."Managers"
  SET contracted_club = NULL,
      contract_seasons_remaining = 0,
      weekly_wage = 0,
      pending_owner_renewal = false,
      updated_at = now()
  WHERE id = p_manager_id;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Cancelled', updated_at = now()
  WHERE manager_id = p_manager_id AND status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'former_club', v_club,
    'payout', v_payout
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_release_from_club(bigint, text, numeric, text, text, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.manager_renewal_window_open(p_gpsl_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT lower(btrim(coalesce(p_gpsl_month, ''))) IN ('june', 'july', 'august');
$function$;

CREATE OR REPLACE FUNCTION public.manager_renewal_deadline_passed(
  p_locked_gpsl_month text DEFAULT NULL,
  p_active_gpsl_month text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_locked text := lower(btrim(coalesce(p_locked_gpsl_month, '')));
  v_active text := lower(btrim(coalesce(p_active_gpsl_month, '')));
BEGIN
  -- End of August lock → deadline fires
  IF v_locked = 'august' THEN
    RETURN true;
  END IF;

  -- Catch-up once the calendar has moved past August
  IF v_active IN (
    'september', 'october', 'november', 'december',
    'january', 'february', 'march', 'april', 'may', 'playoffs'
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

DROP FUNCTION IF EXISTS public.manager_process_pending_renewal_deadline(bigint, text);

-- Release managers still awaiting renewal after the August window
CREATE OR REPLACE FUNCTION public.manager_process_pending_renewal_deadline(
  p_season_id bigint DEFAULT NULL,
  p_locked_gpsl_month text DEFAULT NULL,
  p_notify boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_locked text := nullif(lower(btrim(coalesce(p_locked_gpsl_month, ''))), '');
  v_active text;
  v_mgr public."Managers"%rowtype;
  v_club text;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'results', '[]'::jsonb);
  END IF;

  v_active := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF NOT public.manager_renewal_deadline_passed(v_locked, v_active) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'renewal_window_open',
      'season_id', v_season_id,
      'locked_gpsl_month', v_locked,
      'active_gpsl_month', nullif(v_active, ''),
      'results', '[]'::jsonb
    );
  END IF;

  FOR v_mgr IN
    SELECT *
    FROM public."Managers"
    WHERE pending_owner_renewal IS TRUE
      AND coalesce(contract_seasons_remaining, 0) = 0
      AND contracted_club IS NOT NULL
      AND btrim(contracted_club) <> ''
  LOOP
    v_club := v_mgr.contracted_club;

    PERFORM public.manager_release_from_club(
      v_mgr.id,
      v_club::text,
      v_mgr.market_value::numeric,
      'transfer_sale'::text,
      format(
        'Manager released — renewal not completed by August (%s)',
        coalesce(v_mgr.name, v_mgr.id::text)
      )::text,
      jsonb_build_object(
        'renewal_deadline', true,
        'gpsl_month', coalesce(v_locked, v_active, 'august'),
        'season_id', v_season_id
      )::jsonb
    );

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'manager_id', v_mgr.id,
      'club', v_club,
      'action', 'released_renewal_lapsed',
      'payout', v_mgr.market_value
    ));
  END LOOP;

  IF coalesce(p_notify, true)
     AND jsonb_array_length(v_results) > 0
     AND to_regprocedure('public.owner_inbox_notify_manager_season_end(jsonb)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_manager_season_end(v_results);
  END IF;

  IF v_locked = 'august' THEN
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      'manager_renewal_deadline:august',
      'august',
      jsonb_build_object(
        'ok', true,
        'released', jsonb_array_length(v_results),
        'results', v_results,
        'ran_at', now()
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'locked_gpsl_month', v_locked,
    'active_gpsl_month', nullif(v_active, ''),
    'released', jsonb_array_length(v_results),
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_process_pending_renewal_deadline(bigint, text, boolean)
  TO authenticated, service_role;

-- Owner renew: only June / July / August
CREATE OR REPLACE FUNCTION public.manager_owner_renew()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_mgr public."Managers"%rowtype;
  v_season_id bigint;
  v_month text;
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
    AND pending_owner_renewal IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager renewal pending for your club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF v_month <> '' AND NOT public.manager_renewal_window_open(v_month) THEN
    RAISE EXCEPTION
      'Manager renewal window closed after August. Unrenewed managers are released for market value.';
  END IF;

  UPDATE public."Managers"
  SET contract_seasons_remaining = 2,
      pending_owner_renewal = false,
      signed_season_id = v_season_id,
      deal_start_season_id = v_season_id,
      weekly_wage = public.manager_weekly_wage_for(market_value),
      updated_at = now()
  WHERE id = v_mgr.id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'renewed',
    'manager_id', v_mgr.id,
    'club', v_club,
    'contract_seasons_remaining', 2
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_owner_renew() TO authenticated;

-- Season-end: if still pending past August, release instead of waiting forever
CREATE OR REPLACE FUNCTION public.manager_process_season_end()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_pos smallint;
  v_target public.manager_rating_targets;
  v_met boolean;
  v_deal bigint;
  v_hits int;
  v_misses int;
  v_fail_club text;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_block_err text;
  v_month text;
  v_deadline jsonb;
BEGIN
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'results', '[]'::jsonb);
  END IF;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season.id, now()), ''));

  -- Catch-up: lapse any pending renewals once past August (inbox via with_inbox wrapper)
  IF public.manager_renewal_deadline_passed(NULL, v_month) THEN
    v_deadline := public.manager_process_pending_renewal_deadline(
      v_season.id, NULL, false
    );
    IF jsonb_typeof(v_deadline -> 'results') = 'array' THEN
      v_results := v_results || coalesce(v_deadline -> 'results', '[]'::jsonb);
    END IF;
  END IF;

  FOR v_mgr IN
    SELECT * FROM public."Managers"
    WHERE contracted_club IS NOT NULL
      AND btrim(contracted_club) <> ''
      AND (
        contract_seasons_remaining > 0
        OR pending_owner_renewal IS TRUE
      )
  LOOP
    IF coalesce(v_mgr.pending_owner_renewal, false)
       AND coalesce(v_mgr.contract_seasons_remaining, 0) = 0 THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'awaiting_renewal'
      ));
      CONTINUE;
    END IF;

    SELECT cs.division, cs.season_position
    INTO v_division, v_pos
    FROM public.manager_club_season_position(v_season.id, v_mgr.contracted_club) cs;

    v_target := public.manager_target_for(v_mgr.rating, coalesce(v_division, 'championship_a'));
    v_met := public.manager_target_met(v_target, v_pos, v_division);
    v_deal := coalesce(v_mgr.deal_start_season_id, v_mgr.signed_season_id, v_season.id);

    INSERT INTO public.manager_deal_season_results (
      manager_id, club_short_name, deal_start_season_id, season_id,
      division, final_position, target_kind, target_value, target_label, target_met
    )
    VALUES (
      v_mgr.id, v_mgr.contracted_club, v_deal, v_season.id,
      v_division, v_pos,
      v_target.target_kind, v_target.target_value, v_target.label, v_met
    )
    ON CONFLICT (manager_id, club_short_name, deal_start_season_id, season_id)
    DO UPDATE SET
      division = excluded.division,
      final_position = excluded.final_position,
      target_kind = excluded.target_kind,
      target_value = excluded.target_value,
      target_label = excluded.target_label,
      target_met = excluded.target_met,
      recorded_at = now();

    IF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN
      UPDATE public."Managers"
      SET contract_seasons_remaining = contract_seasons_remaining - 1,
          deal_start_season_id = v_deal,
          pending_owner_renewal = false,
          updated_at = now()
      WHERE id = v_mgr.id;

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'season_tick',
        'position', v_pos,
        'target_met', v_met,
        'seasons_remaining', v_mgr.contract_seasons_remaining - 1
      );
    ELSE
      SELECT
        count(*) FILTER (WHERE target_met IS TRUE)::int,
        count(*) FILTER (WHERE target_met IS FALSE)::int
      INTO v_hits, v_misses
      FROM public.manager_deal_season_results
      WHERE manager_id = v_mgr.id
        AND club_short_name = v_mgr.contracted_club
        AND deal_start_season_id = v_deal;

      IF v_hits >= 1 THEN
        UPDATE public."Managers"
        SET contract_seasons_remaining = 0,
            pending_owner_renewal = true,
            deal_start_season_id = v_deal,
            updated_at = now()
        WHERE id = v_mgr.id;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_mgr.contracted_club,
          'action', 'renewal_available',
          'position', v_pos,
          'target_met', v_met,
          'hits', v_hits,
          'misses', v_misses
        );
      ELSE
        v_fail_club := v_mgr.contracted_club;
        PERFORM public.manager_release_from_club(
          v_mgr.id,
          v_fail_club::text,
          v_mgr.market_value::numeric,
          'transfer_sale'::text,
          format('Manager released — failed targets (%s)', coalesce(v_mgr.name, v_mgr.id::text))::text,
          jsonb_build_object(
            'season_end', true,
            'failed_targets', true,
            'hits', v_hits,
            'misses', v_misses
          )::jsonb
        );

        v_block_err := NULL;
        BEGIN
          PERFORM public.manager_rehire_block_record(
            v_fail_club, v_mgr.id, v_season.id, 2, 'failed_targets'
          );
        EXCEPTION
          WHEN OTHERS THEN
            v_block_err := SQLERRM;
        END;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_fail_club,
          'action', 'released_failed_deal',
          'position', v_pos,
          'target_met', v_met,
          'hits', v_hits,
          'misses', v_misses,
          'payout', v_mgr.market_value,
          'rehire_block_error', v_block_err
        );
      END IF;
    END IF;

    v_results := v_results || jsonb_build_array(v_row);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season.id, 'results', v_results);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_process_season_end() TO authenticated;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_manager_season_end(p_results jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_club text;
  v_action text;
  v_body text;
  v_title text;
BEGIN
  IF p_results IS NULL OR jsonb_typeof(p_results) <> 'array' THEN
    RETURN;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_results)
  LOOP
    v_club := v_row ->> 'club';
    v_action := v_row ->> 'action';
    IF v_club IS NULL OR v_club = '' THEN
      CONTINUE;
    END IF;

    v_title := CASE v_action
      WHEN 'renewal_available' THEN 'Manager renewal available'
      WHEN 'released_failed_deal' THEN 'Manager released'
      WHEN 'released_renewal_lapsed' THEN 'Manager released'
      WHEN 'released' THEN 'Manager released'
      WHEN 'season_tick' THEN 'Manager season reviewed'
      WHEN 'awaiting_renewal' THEN 'Manager renewal pending'
      ELSE 'Manager update'
    END;

    v_body := CASE v_action
      WHEN 'season_tick' THEN format(
        'Your manager finished %s (%s). Contract continues — %s season(s) remaining on this deal.',
        coalesce(v_row ->> 'position', '?'),
        CASE WHEN (v_row ->> 'target_met') = 'true' THEN 'target met' WHEN (v_row ->> 'target_met') = 'false' THEN 'target missed' ELSE 'no evaluation' END,
        coalesce(v_row ->> 'seasons_remaining', '?')
      )
      WHEN 'renewal_available' THEN format(
        'Your manager completed their 2-season deal (finished %s this season). They hit their target in at least one season — renew them from Club Details or Squad by August, or they are released for market value.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'released_failed_deal' THEN format(
        'Your manager missed their target in both seasons of the deal (finished %s this season). They have been released for market value; your club cannot re-sign them for two seasons.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'released_renewal_lapsed' THEN
        'Your manager was eligible for renewal but was not renewed by August. They have been released for market value.'
      WHEN 'released' THEN format(
        'Your manager missed the league target (finished %s). They have been released; your club received market-value compensation.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'awaiting_renewal' THEN
        'Your manager is still awaiting renewal on Club Details / Squad. Renew by August or they will be released for market value.'
      ELSE format('Manager review: %s', v_action)
    END;

    PERFORM public.owner_inbox_send(
      'season_overview',
      v_title,
      v_body,
      v_club,
      NULL, NULL, NULL, NULL, NULL,
      'club_details.html',
      format('mgr_end:%s:%s:%s', v_club, v_action, coalesce(v_row ->> 'manager_id', '')),
      NULL, NULL
    );
  END LOOP;
END;
$function$;

-- Soft-wire into month-lock jobs (August lock / catch-up)
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'manager_process_pending_renewal_deadline';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs(4-arg) missing — wire skipped; call manager_process_pending_renewal_deadline manually';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Manager renewal deadline already wired into month-lock jobs';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out in month-lock jobs — wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.manager_process_pending_renewal_deadline(bigint,text,boolean)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''manager_renewal_deadline'',\n'
    || E'        public.manager_process_pending_renewal_deadline(p_season_id, v_month, true)\n'
    || E'      );\n'
    || E'    ELSIF to_regprocedure(''public.manager_process_pending_renewal_deadline(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''manager_renewal_deadline'',\n'
    || E'        public.manager_process_pending_renewal_deadline(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''manager_renewal_deadline'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n\n'
    || E'  RETURN v_out;\nEND;';

  v_def := replace(v_def, v_old, v_new);

  BEGIN
    EXECUTE v_def;
    RAISE NOTICE 'Wired manager renewal August deadline into competition_run_month_lock_jobs';
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'Month-lock wire failed (%); call manager_process_pending_renewal_deadline manually', SQLERRM;
  END;
END;
$wire$;

NOTIFY pgrst, 'reload schema';
