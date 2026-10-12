-- =============================================================================
-- Friendlies: first 15 paid friendlies per GPSL month earn ₿5,000 (was 10)
-- Season cap ₿750,000 (was ₿500,000). Back-counts this season's friendlies
-- that were skipped by the old month cap. Safe re-run (paid ones are skipped).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_cap()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 15; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_season_cap()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 750000::numeric; $$;

NOTIFY pgrst, 'reload schema';

-- Backfill (current season): friendlies that missed out only because of the
-- old 10-a-month cap are paid now, oldest first, under the new caps.
DROP TABLE IF EXISTS _friendly_backpay;
CREATE TEMP TABLE _friendly_backpay (club text, gpsl_month text, friendly_id bigint, paid numeric, note text);

DO $backpay$
DECLARE
  v_season bigint;
  f record;
  v_side text;
  v_club text;
  v_res jsonb;
  v_scoreline text;
BEGIN
  SELECT id INTO v_season FROM public.competition_seasons
  WHERE is_current = true ORDER BY id DESC LIMIT 1;

  FOR f IN
    SELECT * FROM public.gpsl_friendlies
    WHERE season_id = v_season
      AND (
        (paid_left = 0 AND left_skipped_reason LIKE 'Month cap reached%')
        OR (paid_right = 0 AND right_skipped_reason LIKE 'Month cap reached%')
      )
    ORDER BY confirmed_at, id
  LOOP
    v_scoreline := format('%s %s - %s %s', f.club_left, f.score_left, f.score_right, f.club_right);

    FOREACH v_side IN ARRAY ARRAY['left', 'right'] LOOP
      IF v_side = 'left' THEN
        CONTINUE WHEN NOT (f.paid_left = 0 AND f.left_skipped_reason LIKE 'Month cap reached%');
        v_club := f.club_left;
      ELSE
        CONTINUE WHEN NOT (f.paid_right = 0 AND f.right_skipped_reason LIKE 'Month cap reached%');
        v_club := f.club_right;
      END IF;

      v_res := public.gpsl_friendlies_pay_club(v_season, f.gpsl_month, v_club, f.id, v_scoreline);

      IF v_side = 'left' THEN
        UPDATE public.gpsl_friendlies
        SET paid_left = coalesce((v_res->>'paid')::numeric, 0),
            left_skipped_reason = v_res->>'skipped'
        WHERE id = f.id;
      ELSE
        UPDATE public.gpsl_friendlies
        SET paid_right = coalesce((v_res->>'paid')::numeric, 0),
            right_skipped_reason = v_res->>'skipped'
        WHERE id = f.id;
      END IF;

      INSERT INTO _friendly_backpay VALUES (
        v_club, f.gpsl_month, f.id,
        coalesce((v_res->>'paid')::numeric, 0),
        coalesce(v_res->>'skipped', 'paid (back-counted)')
      );
    END LOOP;
  END LOOP;
END
$backpay$;

-- Report: per club and month, what the back-count paid
SELECT club, gpsl_month,
       count(*) FILTER (WHERE paid > 0) AS newly_paid,
       sum(paid) AS amount,
       count(*) FILTER (WHERE paid = 0) AS still_unpaid,
       string_agg(DISTINCT note, '; ') FILTER (WHERE paid = 0) AS why_unpaid
FROM _friendly_backpay
GROUP BY club, gpsl_month
ORDER BY club, gpsl_month;
