/**
 * Fallback only: video tutorials are managed in admin_video_tutorials.html (database).
 * This list is used just if the video_tutorial_* tables can't be read.
 *
 * Add a video: copy a line like the example below into the right section's `videos` list.
 *   { title: "How to list a player", url: "https://www.youtube.com/watch?v=XXXXXXXXXXX", description: "" },
 *
 * - `title` is the header shown on the page; clicking it opens the video.
 * - YouTube links (watch, youtu.be, /shorts/) also play inline on the page.
 * - Any other link (Streamable, Google Drive, Twitch, etc.) shows as a clickable title card.
 * - `description` is optional.
 * - Sections with no videos are hidden. A section's `id` is its menu link (video_tutorials.html#transfers).
 */
export const VIDEO_TUTORIAL_SECTIONS = [
  {
    id: "transfers",
    title: "Transfers",
    videos: [
      // { title: "How to list a player", url: "https://www.youtube.com/watch?v=XXXXXXXXXXX", description: "" },
    ],
  },
  {
    id: "getting-started",
    title: "Getting started",
    videos: [],
  },
  {
    id: "club-auction",
    title: "Club auction & onboarding",
    videos: [],
  },
  {
    id: "matchday",
    title: "Match day & fixtures",
    videos: [],
  },
  {
    id: "finances",
    title: "Finances & stadium",
    videos: [],
  },
];
