-- Show past GPSL-month fixtures on the dashboard and Club Wire
-- while they are still scheduled (unplayed, not awarded).
-- Safe re-run.

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  -- Dashboard checklist
  v_def := replace(
    pg_get_functiondef('public.matchday_checklist_for_club(text, boolean)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('Past month, still unplayed, not awarded' IN v_def) = 0 THEN
    v_old := replace($old$        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )$old$, E'\r\n', E'\n');
    v_new := replace($new$        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
        -- Past month, still unplayed, not awarded
        OR (
          f.status = 'scheduled'
          AND coalesce(f.is_void, false) = false
          AND cal.unlock_at IS NOT NULL
          AND cal.unlock_at <= v_now
        )$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'checklist past-fixture needle not found';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'checklist past-fixture needle not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  -- Dashboard arrange list
  v_def := replace(
    pg_get_functiondef('public.owner_upcoming_arrangements()'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('Past month, still unplayed, not awarded' IN v_def) = 0 THEN
    v_old := replace($old$        OR (
          to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
      )$old$, E'\r\n', E'\n');
    v_new := replace($new$        OR (
          to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
        -- Past month, still unplayed, not awarded
        OR (
          cal.unlock_at <= now()
          AND coalesce(f.is_void, false) = false
        )
      )$new$, E'\r\n', E'\n');
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'arrangements past-fixture needle not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  -- Club Wire propose / reply cards
  v_def := replace(
    pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('Past month, still unplayed, not awarded' IN v_def) = 0 THEN
    v_old := replace($old$      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '21 days'$old$, E'\r\n', E'\n');
    v_new := replace($new$      AND (
        (cal.unlock_at > now() AND cal.unlock_at <= now() + interval '21 days')
        -- Past month, still unplayed, not awarded
        OR (
          cal.unlock_at <= now()
          AND f.status = 'scheduled'
          AND coalesce(f.is_void, false) = false
        )
      )$new$, E'\r\n', E'\n');
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'wire month-window needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);

    v_old := replace($old$    ELSIF v_state = 'propose' THEN$old$, E'\r\n', E'\n');
    v_new := replace($new$    ELSIF v_state = 'propose' AND r.unlock_at > now() THEN$new$, E'\r\n', E'\n');
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'wire propose branch not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);

    v_old := replace($old$        'fixture_id', r.id
      ));
    END IF;
  END LOOP;

  FOR r IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      s.agreed_kickoff_at$old$, E'\r\n', E'\n');
    v_new := replace($new$        'fixture_id', r.id
      ));
    ELSIF r.unlock_at <= now() THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', CASE WHEN v_state = 'propose' THEN 'propose:' ELSE 'unplayed:' END || r.id::text,
        'kind', CASE WHEN v_state = 'propose' THEN 'propose' ELSE 'play_window' END,
        'at', coalesce(r.response_due_at, now()),
        'title', CASE
          WHEN v_state = 'propose' THEN format('Propose vs %s', v_opp)
          WHEN v_state = 'waiting' THEN format('Reply pending vs %s', v_opp)
          ELSE format('Still unplayed vs %s', v_opp)
        END,
        'detail', CASE
          WHEN v_state = 'propose' THEN 'This GPSL month has opened and the match has not been played or awarded. Home still has to propose.'
          WHEN v_state = 'waiting' THEN 'This GPSL month has opened and the match has not been played or awarded. Waiting on the other club to reply.'
          ELSE 'This GPSL month has opened and the match has not been played or awarded.'
        END,
        'severity', CASE
          WHEN r.response_due_at IS NOT NULL AND r.response_due_at <= now() + interval '2 days' THEN 'warn'
          ELSE 'info'
        END,
        'href', v_href,
        'fixture_id', r.id
      ));
    END IF;
  END LOOP;

  FOR r IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      s.agreed_kickoff_at$new$, E'\r\n', E'\n');
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'wire propose ending not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n');
  v_old := 'Reply before this deadline (often 24h turns)';
  v_new := 'Reply before this deadline. It is 48 hours and can run into the next GPSL month. Missing it is a strike: ₿500k.';
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'reply detail needle not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END
$patch$;
