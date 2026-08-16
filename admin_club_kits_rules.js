/**
 * Club kits admin — intro / setup guidance (modular horizontal cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260816-club-kits";

export function getAdminClubKitsRules() {
  return {
    title: "Club kits",
    lead: `Nav: <b>Admin → Season Break → Club Management → Download Latest Kits</b>.
      PNGs live in <code>images/clubs_kits/</code> on GitHub; owners see them on <b>Club Details</b>.
      Graphics courtesy of
      <a href="https://www.colours-of-football.com/" target="_blank" rel="noopener">colours-of-football.com</a>.`,
    notice: {
      title: "GitHub alone does not install the edge function",
      body: `Until <code>club-kits-cof-sync</code> is deployed (and redeployed after COF mapping fixes),
        <b>Download</b> fails with “Failed to send a request…” or keeps old 404 URLs.
        After editing <code>club_kits_cof.js</code>, run <code>python scripts/bundle_club_kits_edge.py</code>,
        then paste updated <code>index.ts</code> into Supabase and Deploy.`,
    },
    steps: [
      {
        heading: "Create function",
        body: "Supabase → Edge Functions → create <code>club-kits-cof-sync</code>.",
      },
      {
        heading: "Paste &amp; deploy",
        body: "Paste all of <code>supabase/functions/club-kits-cof-sync/index.ts</code> → Deploy.",
      },
      {
        heading: "JWT off + secret",
        body: "Enforce JWT = <b>OFF</b>. Secrets: <code>GITHUB_TOKEN</code> (Contents R/W on the GPSL repo).",
      },
      {
        heading: "SQL once",
        body: "Run <code>supabase/sql/patches/club_kits.sql</code> if not already applied.",
      },
    ],
    cards: [
      {
        heading: "Download latest",
        items: [
          "Pulls from COF, <b>commits PNGs to GitHub</b>, updates <code>club_kits</code>.",
          "Latest season first; older seasons only for clubs still missing kits.",
          "Lines with <code>→ GitHub</code> mean files were pushed (live after Pages deploy).",
          "<b>Save COF links only</b> if <code>GITHUB_TOKEN</code> is not set yet.",
        ],
      },
      {
        heading: "One club / replace",
        items: [
          "Select a club → <b>Preview</b> or <b>Download selected club from COF → GitHub</b>.",
          "Or upload a custom PNG (e.g. clubs not on COF).",
          "Paths: <code>images/clubs_kits/{SHORT}_home.png</code> (and away / third).",
        ],
      },
      {
        heading: "COF lookup",
        items: [
          "Nation folder is often a short code (<code>mex/</code>, <code>eng/</code>); the index page may be the full name (<code>mexico.html</code>).",
          "Club pages use a slug under that folder (e.g. <code>mex/tigres/</code>).",
          "Hard cases: <code>COF_CLUB_SLUG_OVERRIDES</code> in <code>club_kits_cof.js</code>, then re-bundle + redeploy.",
          "See <code>scripts/README_club_kits_cof.md</code>.",
        ],
      },
      {
        heading: "Manual URL save",
        items: [
          "Editor fields override defaults; leave blank to use the standard GitHub path.",
          "<b>Save kits</b> writes URLs to <code>club_kits</code> only (does not push PNGs).",
        ],
      },
    ],
  };
}

export function renderAdminClubKitsRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("clubKitsRules") ||
    document.querySelector(".club-kits-rules");
  renderRulesPanel(root, getAdminClubKitsRules(), {
    rootClass: "info-box info-box--wide club-kits-rules",
  });
}
