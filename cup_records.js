import { CUP_RECORD_GROUPS } from "./records_catalog.js?v=20261113-drop-empty";
import { mountRecordsPage } from "./records_page.js?v=20261113-division-tabs";

mountRecordsPage({
  title: "Cup Records",
  catalog: "cup",
  intro:
    "All-time cup marks across League Cup, World Cup and Prestige Cups — clubs, finals, players and managers. Recomputed every Monday from played cup fixtures.",
  groups: CUP_RECORD_GROUPS,
  siblingLinks: [
    { href: "league_records.html", label: "League Records" },
    { href: "fun_records.html", label: "Fun Records" },
  ],
});
