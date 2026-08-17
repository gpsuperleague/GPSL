/**
 * International & World Cup admin — intro / process notes (modular horizontal cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260817-qual-fill";

export function getAdminInternationalRules() {
  return {
    title: "International &amp; World Cup",
    lead: `<a href="admin.html">← Admin hub</a>
      · Nation setup, WC cycle, owner rankings, assign override, and selection windows.
      First deploy: run
      <code>supabase/sql/patches/international_refresh_selectable_and_seed_ranks.sql</code>
      (and <code>competition_owner_ranking.sql</code> once if rankings are missing).`,
    notice: {
      title: "Run Setup one step at a time",
      body: `Each Setup button can take ~1–2 min. Do <b>not</b> combine them in one SQL query —
        Supabase times out long combined jobs. If a button times out, run the matching
        <code>SELECT …</code> alone in the SQL Editor.`,
    },
    steps: [
      {
        heading: "Import labels",
        body: "Add missing nationalities from GPDB.",
      },
      {
        heading: "Refresh pool",
        body: "Recount players by rating band (slowest).",
      },
      {
        heading: "Apply selectable",
        body: "Activate nations with ≥26 GPDB players and ≥2 GKs (26–28 call-up bar).",
      },
      {
        heading: "Seed ranks",
        body: "Order by average rating of top 100 GPDB players (seed 1 = strongest).",
      },
    ],
    cards: [
      {
        heading: "World Cup cycle",
        items: [
          "<b>Standard:</b> create a cycle, bind two qualifying seasons + the season whose <b>pre-season</b> hosts finals.",
          "<b>Popup (test):</b> one season only — qual + finals June→May (single RR, play once).",
          "Qualifying: <b>12 groups × 5</b> (pots by seed rank).",
          "Finals: top 2 + 8 best thirds → <b>8×4</b> → knockout.",
          "Draw field: <b>all owned nations</b>, then fill to 60 with <b>unassigned active</b> nations (by seed). Fillers have no owner — force-play those fixtures when testing.",
        ],
      },
      {
        heading: "Qualifying calendar",
        items: [
          "<b>Standard:</b> each nation plays <b>8 matches</b> (H&amp;A) — <b>4 per season</b> across two seasons; windows Aug/Oct/Dec/Feb/Apr.",
          "<b>Popup:</b> each nation plays <b>4 matches</b> (once vs each other) — windows <b>June / Aug / Oct / Dec / Feb</b>.",
          "Group size 5 → <b>5 international windows</b> (one bye each window).",
        ],
      },
      {
        heading: "Finals &amp; seasons",
        items: [
          "<b>Standard finals:</b> pre-season of the next season (June/July).",
          "<b>Popup finals:</b> same season — groups Mar–Apr, knockout <b>May</b> (not pre-season).",
          "If S3 / S4 / S5 are missing for a standard cycle, use <b>Create missing seasons</b> first.",
          "Shells are status <code>setup</code> — does not start those seasons or Create Pre-Season.",
        ],
      },
      {
        heading: "Fixtures surfaces",
        items: [
          "World Cup page lists all cycle fixtures.",
          "Owners also see their nation’s matches on <b>My Club Fixtures</b> (month groups) and season calendar.",
          "Play / arrange via <b>International matchday</b>.",
        ],
      },
      {
        heading: "Dry-run / testing",
        items: [
          "Force-play remaining fixtures with deterministic scores (KO avoids 90-min draws).",
          "Smoke-tests thirds ranking, finals draw, and KO advance.",
          "Does <b>not</b> replace real owner results.",
        ],
      },
      {
        heading: "Owner rankings",
        items: [
          "Nation draft order = <b>rolling points from the last four seasons</b> (auto on archive).",
          "Recompute only for backfill or after a formula patch.",
          "Public: <a href=\"owner_rankings.html\">Owner rankings</a> (click an owner).",
        ],
      },
      {
        heading: "Assign / selection",
        items: [
          "Admin override: reassign frees the old nation; taken nations stay greyed out.",
          "<b>Remove from nation</b> frees that club only (selection window unchanged).",
          "Open / Close / Clear each have their own admin page (separate checklist ticks).",
        ],
      },
    ],
  };
}

export function renderAdminInternationalRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("intlRules") ||
    document.querySelector(".intl-rules");
  renderRulesPanel(root, getAdminInternationalRules(), {
    rootClass: "info-box info-box--wide intl-rules",
  });
}
