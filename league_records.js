import { LEAGUE_RECORD_GROUPS } from "./records_catalog.js";
import { mountRecordsPage } from "./records_page.js?v=20261113-division-tabs";

mountRecordsPage({
  title: "League Records",
  catalog: "league",
  intro:
    "All-time marks for one division. Championship covers both Championship groups. Recomputed every Monday from live results and season archives.",
  tiers: [
    { id: "superleague", label: "Super League" },
    { id: "championship", label: "Championship" },
  ],
  groups: LEAGUE_RECORD_GROUPS,
  siblingLinks: [
    { href: "cup_records.html", label: "Cup Records" },
    { href: "fun_records.html", label: "Fun Records" },
  ],
});
