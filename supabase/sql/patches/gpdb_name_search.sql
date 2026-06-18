-- GPDB accent-insensitive player name search
-- Run once in Supabase SQL Editor.
--
-- Adds name_search_key (normalized Name) so GPDB can ilike against the full Players table
-- while ignoring accents and punctuation (José → jose, O'Brien → o brien).

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.gpdb_unaccent(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
STRICT
SET search_path = extensions, public
AS $$
  SELECT extensions.unaccent(p_value);
$$;

CREATE OR REPLACE FUNCTION public.gpdb_normalize_search_text(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $$
  SELECT trim(
    both ' '
    from regexp_replace(
      regexp_replace(
        lower(public.gpdb_unaccent(coalesce(p_value, ''))),
        '[^a-z0-9]+',
        ' ',
        'g'
      ),
      '\s+',
      ' ',
      'g'
    )
  );
$$;

COMMENT ON FUNCTION public.gpdb_normalize_search_text(text) IS
  'Lowercase, strip accents, fold punctuation to spaces — matches GPDB client search.';

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS name_search_key text
  GENERATED ALWAYS AS (public.gpdb_normalize_search_text("Name")) STORED;

COMMENT ON COLUMN public."Players".name_search_key IS
  'Accent/punctuation-normalized Name for GPDB search (generated).';

CREATE INDEX IF NOT EXISTS idx_players_name_search_key_trgm
  ON public."Players"
  USING gin (name_search_key extensions.gin_trgm_ops);

GRANT EXECUTE ON FUNCTION public.gpdb_normalize_search_text(text) TO authenticated, anon;
