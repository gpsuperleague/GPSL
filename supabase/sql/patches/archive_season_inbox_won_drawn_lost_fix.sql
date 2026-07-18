-- Fix archive → owner inbox overview: competition_club_season_archive uses
-- won/drawn/lost, not w/d/l. Safe to re-run.

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_club_season_archive(
  p_season_id bigint,
  p_season_label text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_award record;
  v_mgr public."Managers"%rowtype;
  v_star text;
  v_award_lines text[] := ARRAY[]::text[];
  v_overview text;
BEGIN
  FOR v_club IN
    SELECT
      a.club_short_name,
      a.division,
      a.final_position,
      a.pts,
      a.won AS w,
      a.drawn AS d,
      a.lost AS l,
      c."Club" AS club_name
    FROM public.competition_club_season_archive a
    JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
    WHERE a.season_id = p_season_id
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" cx
        WHERE cx."ShortName" = a.club_short_name
          AND cx.owner_id IS NOT NULL
      )
  LOOP
    v_award_lines := ARRAY[]::text[];

    FOR v_award IN
      SELECT aw.award_type, aw.stat_value, aw.detail, p."Name" AS player_name
      FROM public.competition_season_award aw
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = aw.player_id
      WHERE aw.season_id = p_season_id
        AND aw.club_short_name = v_club.club_short_name
      ORDER BY aw.award_type
    LOOP
      v_award_lines := array_append(
        v_award_lines,
        format(
          '%s: %s (%s)',
          replace(v_award.award_type, '_', ' '),
          v_award.player_name,
          v_award.stat_value
        )
      );
    END LOOP;

    IF coalesce(array_length(v_award_lines, 1), 0) > 0 THEN
      PERFORM public.owner_inbox_send(
        'player_awards',
        format('Season awards — %s', p_season_label),
        array_to_string(v_award_lines, E'\n'),
        v_club.club_short_name,
        NULL,
        NULL, NULL, NULL, NULL,
        'history.html',
        format('awards:%s:%s', p_season_id, v_club.club_short_name),
        NULL,
        p_season_id
      );
    END IF;

    SELECT * INTO v_mgr
    FROM public."Managers" m
    WHERE m.contracted_club = v_club.club_short_name
    LIMIT 1;

    SELECT p."Name" INTO v_star
    FROM public.competition_player_season_archive ps
    JOIN public."Players" p ON p."Konami_ID"::text = ps.player_id
    WHERE ps.season_id = p_season_id
      AND ps.club_short_name = v_club.club_short_name
    ORDER BY ps.ballon_points DESC, ps.goals DESC
    LIMIT 1;

    v_overview := concat_ws(
      E'\n',
      format(
        'Final league position: %s in %s (%s pts, %sW-%sD-%sL)',
        v_club.final_position,
        v_club.division,
        v_club.pts,
        v_club.w,
        v_club.d,
        v_club.l
      ),
      CASE
        WHEN v_mgr.id IS NOT NULL THEN
          format(
            'Manager: %s — %s season(s) on contract',
            v_mgr.name,
            v_mgr.contract_seasons_remaining
          )
        ELSE 'Manager: none signed'
      END,
      CASE WHEN v_star IS NOT NULL THEN 'Star player: ' || v_star ELSE NULL END,
      'See Club History and Owner Rankings for the full season breakdown.'
    );

    PERFORM public.owner_inbox_send(
      'season_overview',
      format('Season overview — %s', p_season_label),
      v_overview,
      v_club.club_short_name,
      NULL,
      NULL, NULL, NULL, NULL,
      'history.html',
      format('season_overview:%s:%s', p_season_id, v_club.club_short_name),
      NULL,
      p_season_id
    );
  END LOOP;
END;
$function$;
