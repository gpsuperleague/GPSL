-- Video tutorials managed from admin_video_tutorials.html.
-- Folders can nest (parent_id). Top-level folders with show_in_menu appear under
-- Owners → Knowledge → Video tutorials in the nav. Everyone can read; admins write.

CREATE TABLE IF NOT EXISTS public.video_tutorial_folders (
  id           bigserial PRIMARY KEY,
  parent_id    bigint REFERENCES public.video_tutorial_folders(id) ON DELETE CASCADE,
  title        text NOT NULL CHECK (btrim(title) <> ''),
  slug         text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]*$'),
  description  text,
  sort_order   integer NOT NULL DEFAULT 0,
  show_in_menu boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE TABLE IF NOT EXISTS public.video_tutorial_links (
  id          bigserial PRIMARY KEY,
  folder_id   bigint NOT NULL REFERENCES public.video_tutorial_folders(id) ON DELETE CASCADE,
  title       text NOT NULL CHECK (btrim(title) <> ''),
  url         text NOT NULL CHECK (url ~* '^https?://'),
  description text,
  sort_order  integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS video_tutorial_folders_parent_idx ON public.video_tutorial_folders(parent_id);
CREATE INDEX IF NOT EXISTS video_tutorial_links_folder_idx ON public.video_tutorial_links(folder_id);

ALTER TABLE public.video_tutorial_folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.video_tutorial_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS video_tutorial_folders_read ON public.video_tutorial_folders;
CREATE POLICY video_tutorial_folders_read ON public.video_tutorial_folders
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS video_tutorial_folders_admin_write ON public.video_tutorial_folders;
CREATE POLICY video_tutorial_folders_admin_write ON public.video_tutorial_folders
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS video_tutorial_links_read ON public.video_tutorial_links;
CREATE POLICY video_tutorial_links_read ON public.video_tutorial_links
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS video_tutorial_links_admin_write ON public.video_tutorial_links;
CREATE POLICY video_tutorial_links_admin_write ON public.video_tutorial_links
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.video_tutorial_folders, public.video_tutorial_links TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.video_tutorial_folders, public.video_tutorial_links TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.video_tutorial_folders_id_seq, public.video_tutorial_links_id_seq TO authenticated;
GRANT ALL ON public.video_tutorial_folders, public.video_tutorial_links TO service_role;

INSERT INTO public.video_tutorial_folders (title, slug, sort_order)
VALUES ('Transfers', 'transfers', 10)
ON CONFLICT (slug) DO NOTHING;

SELECT id, parent_id, title, slug, sort_order, show_in_menu
FROM public.video_tutorial_folders
ORDER BY sort_order, id;
