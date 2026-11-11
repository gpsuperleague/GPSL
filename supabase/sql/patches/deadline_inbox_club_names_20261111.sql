-- Deadline inbox and calendar titles used the opponent short code (vs CHE).
-- Use the club's full name, and rewrite warnings already sitting in the inbox.

DO $patch$
DECLARE
  v_def text;
  v_old_opp text := $old$
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;$old$;
  v_new_opp text := $new$
    v_opp := CASE WHEN v_side = 'home'
      THEN coalesce(public.club_display_name(r.away_club_short_name), r.away_club_short_name)
      ELSE coalesce(public.club_display_name(r.home_club_short_name), r.home_club_short_name) END;$new$;
  v_old_video text := $old$
        CASE
          WHEN upper(btrim(f.home_club_short_name)) = v_club THEN upper(btrim(f.away_club_short_name))
          ELSE upper(btrim(f.home_club_short_name))
        END AS opp,$old$;
  v_new_video text := $new$
        CASE
          WHEN upper(btrim(f.home_club_short_name)) = v_club
            THEN coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
          ELSE coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name)
        END AS opp,$new$;
BEGIN
  v_def := pg_get_functiondef('public.owner_personal_deadlines(text)'::regprocedure);

  IF position(v_old_opp IN v_def) = 0 THEN
    RAISE EXCEPTION 'owner_personal_deadlines: short-code opponent block not found';
  END IF;
  v_def := replace(v_def, v_old_opp, v_new_opp);

  IF position(v_old_video IN v_def) > 0 THEN
    v_def := replace(v_def, v_old_video, v_new_video);
  END IF;

  EXECUTE v_def;
END;
$patch$;

UPDATE public.competition_inbox i
SET title = regexp_replace(
  i.title,
  ' vs ([A-Z0-9]{2,8})$',
  ' vs ' || coalesce(
    public.club_display_name((regexp_match(i.title, ' vs ([A-Z0-9]{2,8})$'))[1]),
    (regexp_match(i.title, ' vs ([A-Z0-9]{2,8})$'))[1]
  )
)
WHERE i.message_type = 'owner_deadline_warning'
  AND i.title ~ ' vs [A-Z0-9]{2,8}$'
  AND public.club_display_name((regexp_match(i.title, ' vs ([A-Z0-9]{2,8})$'))[1])
      IS DISTINCT FROM (regexp_match(i.title, ' vs ([A-Z0-9]{2,8})$'))[1];

NOTIFY pgrst, 'reload schema';
