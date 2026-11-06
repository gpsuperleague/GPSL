select proname, pg_get_function_identity_arguments(oid) as args
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in (
    'match_schedule_play_now_session_tick',
    'match_schedule_checkin_opens_at',
    'match_schedule_checkin_minutes',
    'match_schedule_agreed_kickoff'
  );
