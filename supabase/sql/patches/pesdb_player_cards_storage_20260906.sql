-- =============================================================================
-- PESDB player cards: local cache bucket
--
-- Public read so site pages can load cached images directly after the first
-- edge-function fetch. Writes are performed by service-role edge functions.
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'player-cards',
  'player-cards',
  true,
  1048576,
  ARRAY['image/png', 'image/jpeg', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE
SET public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS player_cards_public_read ON storage.objects;
CREATE POLICY player_cards_public_read ON storage.objects
  FOR SELECT TO authenticated, anon
  USING (bucket_id = 'player-cards');

NOTIFY pgrst, 'reload schema';
