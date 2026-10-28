import { FUN_RECORD_GROUPS } from "./records_catalog.js";
import { mountRecordsPage } from "./records_page.js";

mountRecordsPage({
  title: "Fun Records",
  intro:
    "GPSL-style curios — giant killings, final-day drama, bookies fortunes, transfer sprees and stadium lore. The ones owners argue about in Natter.",
  groups: FUN_RECORD_GROUPS,
  siblingLinks: [
    { href: "league_records.html", label: "League Records" },
    { href: "cup_records.html", label: "Cup Records" },
  ],
});
