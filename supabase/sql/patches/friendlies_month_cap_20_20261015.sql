-- =============================================================================
-- Friendlies: first 20 paid friendlies per GPSL month earn ₿5,000 (was 15)
-- Season cap ₿1,200,000 (was ₿750,000): 12 months (June → May) × 20 × ₿5,000.
-- Back-counts this season's friendlies skipped by the old month or season cap,
-- oldest first, under the new caps. Safe re-run (paid ones are skipped).
-- The monthly friendlies table also counts up to 20 per club per month.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_cap()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 20; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_season_cap()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 1200000::numeric; $$;

NOTIFY pgrst, 'reload schema';

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
        (paid_left = 0 AND (left_skipped_reason LIKE 'Month cap reached%' OR left_skipped_reason LIKE 'Season cap reached%'))
        OR (paid_right = 0 AND (right_skipped_reason LIKE 'Month cap reached%' OR right_skipped_reason LIKE 'Season cap reached%'))
      )
    ORDER BY confirmed_at, id
  LOOP
    v_scoreline := format('%s %s - %s %s', f.club_left, f.score_left, f.score_right, f.club_right);

    FOREACH v_side IN ARRAY ARRAY['left', 'right'] LOOP
      IF v_side = 'left' THEN
        CONTINUE WHEN NOT (f.paid_left = 0 AND (f.left_skipped_reason LIKE 'Month cap reached%' OR f.left_skipped_reason LIKE 'Season cap reached%'));
        v_club := f.club_left;
      ELSE
        CONTINUE WHEN NOT (f.paid_right = 0 AND (f.right_skipped_reason LIKE 'Month cap reached%' OR f.right_skipped_reason LIKE 'Season cap reached%'));
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

-- Report: new caps, then per club and month what the back-count paid
SELECT
  public.gpsl_friendlies_month_cap() AS month_cap,
  public.gpsl_friendlies_season_cap() AS season_cap,
  b.club, b.gpsl_month,
  count(*) FILTER (WHERE b.paid > 0) AS newly_paid,
  sum(b.paid) AS amount,
  count(*) FILTER (WHERE b.paid = 0) AS still_unpaid,
  string_agg(DISTINCT b.note, '; ') FILTER (WHERE b.paid = 0) AS why_unpaid
FROM (SELECT 1) one
LEFT JOIN _friendly_backpay b ON true
GROUP BY b.club, b.gpsl_month
ORDER BY b.club NULLS FIRST, b.gpsl_month;
