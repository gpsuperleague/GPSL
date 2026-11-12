-- Public home for league announcement posters.
-- Safe re-run.

INSERT INTO storage.buckets (id, name, public)
VALUES ('posters', 'posters', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS posters_storage_read ON storage.objects;
CREATE POLICY posters_storage_read ON storage.objects
  FOR SELECT TO public
  USING (bucket_id = 'posters');
