-- Expose gpsl_month on public season awards (player profile Team of the Month).
-- Safe to run after competition_totm_tots_awards.sql (column already exists).

ALTER TABLE public.competition_season_award
  ADD COLUMN IF NOT EXISTS gpsl_month text;

DROP VIEW IF EXISTS public.competition_season_awards_public;

CREATE VIEW public.competition_season_awards_public
WITH (security_invoker = false)
AS
SELECT
  a.season_id,
  a.season_label,
  a.award_type,
  a.gpsl_month,
  a.player_id,
  p."Name" AS player_name,
  a.club_short_name,
  c."Club" AS club_name,
  a.stat_value,
  a.detail,
  a.awarded_at
FROM public.competition_season_award a
JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
JOIN public."Clubs" c ON c."ShortName" = a.club_short_name;

GRANT SELECT ON public.competition_season_awards_public TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
