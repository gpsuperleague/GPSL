import { LEAGUE_RECORD_GROUPS } from "./records_catalog.js";
import { mountRecordsPage } from "./records_page.js";

mountRecordsPage({
  title: "League Records",
  intro:
    "All-time Super League & Championship marks — clubs, matches, managers and players. Holders will fill in as seasons complete.",
  groups: LEAGUE_RECORD_GROUPS,
  siblingLinks: [
    { href: "cup_records.html", label: "Cup Records" },
    { href: "fun_records.html", label: "Fun Records" },
  ],
});
