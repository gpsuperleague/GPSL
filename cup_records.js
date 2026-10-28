import { CUP_RECORD_GROUPS } from "./records_catalog.js";
import { mountRecordsPage } from "./records_page.js";

mountRecordsPage({
  title: "Cup Records",
  intro:
    "All-time cup marks across League Cup, World Cup and Prestige Cups — clubs, finals, players and managers. Holders will fill in as campaigns complete.",
  groups: CUP_RECORD_GROUPS,
  siblingLinks: [
    { href: "league_records.html", label: "League Records" },
    { href: "fun_records.html", label: "Fun Records" },
  ],
});
