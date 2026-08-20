/**
 * GPDB ↔ PESDB sync — intro / workflow notes (modular horizontal cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260816-gpdb-sync";

export function getAdminGpdbSyncRules() {
  return {
    title: "GPDB ↔ PESDB sync",
    lead: `<a href="admin.html">← Admin hub</a>
      · Scrape from <a href="https://pesdb.net/efootball/" target="_blank" rel="noopener">pesdb.net</a>,
      preview, then apply.
      Needs <code>patches/gpdb_pesdb_sync.sql</code> + edge <code>gpdb-pesdb-scrape</code>
      (see <code>scripts/README_pesdb_sync.md</code>).
      <b>Back up Players</b> first (<code>export_players_csv.sql</code>).`,
    steps: [
      {
        heading: "Scrape",
        body: "PESDB → staging (or CSV upload).",
      },
      {
        heading: "Preview",
        body: "Dry run vs live <code>Players</code>.",
      },
      {
        heading: "Apply",
        body: "Off-PESDB cards → <b>legacy</b> (stay at club, not sellable, 1-season renewals).",
      },
    ],
    cards: [
      {
        heading: "Playstyles (Att / Def)",
        items: [
          "eFootball cards now have <b>Attacking</b> + <b>Defensive</b> playstyles; one side is often <code>Basic</code>.",
          "GPSL keeps <b>one</b> Playstyle: prefer Att if real, else Def.",
          "Use <b>Refresh playstyles only</b> to rewrite live <code>Players.Playstyle</code> without a full sync apply.",
          "Progress is <b>checkpointed in the DB</b> — reload the page and Start again with <b>Resume</b> checked.",
          "SQL: <code>gpdb_pesdb_playstyle_att_def_20260820.sql</code> + redeploy <code>gpdb-pesdb-scrape</code>.",
        ],
      },
      {
        heading: "Scrape pace",
        items: [
          "~<b>2 list pages</b> per session (~32 players each).",
          "Works in <b>2-page batches</b> with cooldown (same idea as the Python script).",
          "Progress saves after each page — <b>refresh is safe</b>; auto-continues when you reopen.",
          "Test pages <b>1–2</b> first. CSV upload remains as fallback.",
        ],
      },
      {
        heading: "Staging &amp; progress",
        items: [
          "Rows live in <code>gpdb_pesdb_staging</code>.",
          "Job state is in the DB — closing the browser pauses until you open this page again.",
          "Use <b>Mark scrape complete</b> / <b>Clear staging</b> when you need a clean restart.",
        ],
      },
      {
        heading: "Preview",
        items: [
          "No writes to <code>Players</code>.",
          "Check <b>summary counts</b> first; table defaults to <b>Updates (existing GPDB)</b>.",
          "New PESDB cards are listed separately (often thousands).",
        ],
      },
      {
        heading: "Apply &amp; legacy",
        items: [
          "Updates matched players; marks missing as legacy; inserts new free agents.",
          "Type <b>SYNC GPDB</b> to confirm apply.",
          "Legacy: keep at club, not sellable, renew 1 season at a time.",
        ],
      },
    ],
  };
}

export function renderAdminGpdbSyncRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("gpdbSyncRules") ||
    document.querySelector(".gpdb-sync-rules");
  renderRulesPanel(root, getAdminGpdbSyncRules(), {
    rootClass: "info-box info-box--wide gpdb-sync-rules",
  });
}
