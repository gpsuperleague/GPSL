-- Same owner, both videos of one match: the second approval still stands.
-- They are not paid a second ₿2,000. A different owner on the other video is.

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('reward once per match' IN v_def) > 0 THEN
    RETURN;
  END IF;
  v_old := replace($old$
  BEGIN
    PERFORM public.owner_wallet_ensure(v_r.reporter_owner_id);
    v_reward_id := public._post_owner_ledger_internal($old$, E'\r\n', E'\n');
  v_new := replace($new$
  -- reward once per match for this owner; the other video is still approved
  IF EXISTS (
    SELECT 1
    FROM public.match_video_breach_reports prev
    WHERE prev.fixture_id = v_r.fixture_id
      AND prev.id <> p_report_id
      AND prev.reporter_owner_id = v_r.reporter_owner_id
      AND prev.reward_ledger_id IS NOT NULL
      AND prev.status IN ('approved', 'upheld')
  ) THEN
    v_reward_id := NULL;
    v_reward := 0;
  ELSE
  BEGIN
    PERFORM public.owner_wallet_ensure(v_r.reporter_owner_id);
    v_reward_id := public._post_owner_ledger_internal($new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'reward block not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$
  EXCEPTION WHEN OTHERS THEN
    v_reward_id := NULL;
  END;$old$, E'\r\n', E'\n');
  v_new := replace($new$
  EXCEPTION WHEN OTHERS THEN
    v_reward_id := NULL;
  END;
  END IF;$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'reward exception not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$wire$;

SELECT position(
  'reward once per match'
  IN pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'::regprocedure)
) > 0 AS once_per_match;
