-- =============================================================================
-- Track Discord welcome-pack DMs (once per discord_user_id).
-- Used by edge function discord-welcome-pack.
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_welcome_sent (
  discord_user_id text PRIMARY KEY,
  sent_at timestamptz NOT NULL DEFAULT now(),
  ok boolean NOT NULL DEFAULT false,
  via text,
  dm_channel_id text,
  error text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_discord_welcome_sent_sent_at_idx
  ON public.gpsl_discord_welcome_sent (sent_at DESC);

REVOKE ALL ON TABLE public.gpsl_discord_welcome_sent FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.gpsl_discord_welcome_sent TO service_role;
GRANT ALL ON TABLE public.gpsl_discord_welcome_sent TO postgres;

NOTIFY pgrst, 'reload schema';
