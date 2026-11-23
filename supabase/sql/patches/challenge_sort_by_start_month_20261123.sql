-- Start and mid challenge lists follow sort_order.
-- Within each season and window: earlier start month first, then the target
-- that finishes sooner. A single month therefore sits above a longer target
-- that starts in that same month. Same start and end keep their previous order.

CREATE OR REPLACE FUNCTION public.competition_resequence_challenge_sort(
  p_season_id bigint DEFAULT NULL,
  p_window_phase text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.competition_challenge_config c
  SET sort_order = ranked.rn
  FROM (
    SELECT
      id,
      (
        row_number() OVER (
          PARTITION BY season_id, window_phase
          ORDER BY
            public.competition_challenge_month_sort(gpsl_month_from),
            public.competition_challenge_month_sort(gpsl_month_to),
            sort_order,
            id
        )
      )::smallint AS rn
    FROM public.competition_challenge_config
    WHERE (p_season_id IS NULL OR season_id = p_season_id)
      AND (
        p_window_phase IS NULL
        OR window_phase = lower(btrim(p_window_phase))
      )
  ) ranked
  WHERE c.id = ranked.id
    AND c.sort_order IS DISTINCT FROM ranked.rn;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_resequence_challenge_sort(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_resequence_challenge_sort(bigint, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.trg_competition_challenge_config_resequence_sort()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.competition_resequence_challenge_sort(NULL, NULL);
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_challenge_config_resequence_sort
  ON public.competition_challenge_config;

CREATE TRIGGER trg_competition_challenge_config_resequence_sort
  AFTER INSERT OR DELETE
     OR UPDATE OF season_id, window_phase, gpsl_month_from, gpsl_month_to
  ON public.competition_challenge_config
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.trg_competition_challenge_config_resequence_sort();

SELECT public.competition_resequence_challenge_sort(NULL, NULL);

DO $check$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT
        sort_order,
        row_number() OVER (
          PARTITION BY season_id, window_phase
          ORDER BY
            public.competition_challenge_month_sort(gpsl_month_from),
            public.competition_challenge_month_sort(gpsl_month_to),
            sort_order,
            id
        ) AS rn
      FROM public.competition_challenge_config
    ) x
    WHERE sort_order IS DISTINCT FROM rn
  ) THEN
    RAISE EXCEPTION 'challenge sort_order does not follow start month';
  END IF;
END;
$check$;

SELECT 'ready' AS ready;
