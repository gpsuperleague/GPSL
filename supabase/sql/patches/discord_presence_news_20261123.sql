-- Who is currently in the Discord server, so the welcome check can tell
-- a new visitor from someone already here, and can see who has left.
-- The first fill is silent. Later joins and leaves post to #gpsl-news.

CREATE TABLE IF NOT EXISTS public.gpsl_discord_guild_seen (
  discord_user_id text PRIMARY KEY,
  display_name text,
  tier text NOT NULL CHECK (tier IN ('visitor', 'member', 'owner')),
  joined_at timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  seen_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE public.gpsl_discord_guild_seen FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.gpsl_discord_guild_seen TO service_role;
GRANT ALL ON TABLE public.gpsl_discord_guild_seen TO postgres;

NOTIFY pgrst, 'reload schema';

SELECT 'ready' AS ready;
