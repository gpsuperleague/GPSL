/** Shared loaders/helpers for video tutorials (public page, admin page, nav). */

export const VT_MENU_CACHE_KEY = "gpsl_vt_menu_folders_v1";
const VT_MENU_CACHE_MS = 10 * 60 * 1000;

export function youtubeId(url) {
  const s = String(url || "").trim();
  const m =
    s.match(/youtu\.be\/([\w-]{11})/) ||
    s.match(/[?&]v=([\w-]{11})/) ||
    s.match(/youtube\.com\/(?:embed|shorts|live)\/([\w-]{11})/);
  return m ? m[1] : null;
}

export function slugify(text) {
  return (
    String(text || "")
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "")
      .replace(/&/g, " and ")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60) || "folder"
  );
}

const bySort = (a, b) =>
  (a.sort_order ?? 0) - (b.sort_order ?? 0) || String(a.title).localeCompare(String(b.title)) || a.id - b.id;

/** @returns {Promise<{folders: any[], links: any[], error: any}>} */
export async function loadVideoTutorials(supabase) {
  const [fRes, lRes] = await Promise.all([
    supabase
      .from("video_tutorial_folders")
      .select("id, parent_id, title, slug, description, sort_order, show_in_menu"),
    supabase
      .from("video_tutorial_links")
      .select("id, folder_id, title, url, description, sort_order"),
  ]);
  const error = fRes.error || lRes.error || null;
  return {
    folders: (fRes.data || []).slice().sort(bySort),
    links: (lRes.data || []).slice().sort(bySort),
    error,
  };
}

export function sortVt(list) {
  return list.slice().sort(bySort);
}

/** Top-level folders flagged for the nav (cached briefly in sessionStorage). */
export async function loadVideoTutorialMenuFolders(supabase) {
  try {
    const cached = JSON.parse(sessionStorage.getItem(VT_MENU_CACHE_KEY) || "null");
    if (cached && Date.now() - cached.at < VT_MENU_CACHE_MS) return cached.folders;
  } catch {
    /* ignore */
  }
  const { data, error } = await supabase
    .from("video_tutorial_folders")
    .select("title, slug, sort_order, show_in_menu, parent_id")
    .is("parent_id", null)
    .eq("show_in_menu", true);
  if (error) return [];
  const folders = (data || [])
    .slice()
    .sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0) || String(a.title).localeCompare(String(b.title)))
    .map((f) => ({ title: f.title, slug: f.slug }));
  try {
    sessionStorage.setItem(VT_MENU_CACHE_KEY, JSON.stringify({ at: Date.now(), folders }));
  } catch {
    /* ignore */
  }
  return folders;
}

export function clearVideoTutorialMenuCache() {
  try {
    sessionStorage.removeItem(VT_MENU_CACHE_KEY);
  } catch {
    /* ignore */
  }
}
