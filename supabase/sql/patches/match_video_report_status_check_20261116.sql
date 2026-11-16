-- Approve / Reject write approved and rejected.
-- The live check still only allowed open, upheld, dismissed.

ALTER TABLE public.match_video_breach_reports
  DROP CONSTRAINT IF EXISTS match_video_breach_reports_status_check;

ALTER TABLE public.match_video_breach_reports
  ADD CONSTRAINT match_video_breach_reports_status_check
  CHECK (status IN ('open', 'upheld', 'dismissed', 'approved', 'rejected'));

SELECT pg_get_constraintdef(c.oid) AS def
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public'
  AND t.relname = 'match_video_breach_reports'
  AND c.conname = 'match_video_breach_reports_status_check';
