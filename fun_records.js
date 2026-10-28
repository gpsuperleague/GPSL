import { FUN_RECORD_GROUPS } from "./records_catalog.js";
import { mountRecordsPage } from "./records_page.js";

mountRecordsPage({
  title: "Fun Records",
  catalog: "fun",
  intro:
    "GPSL-style curios — giant killings, final-day drama, bank balances and more. Recomputed every Monday; more categories light up as data exists.",
  groups: FUN_RECORD_GROUPS,
  siblingLinks: [
    { href: "league_records.html", label: "League Records" },
    { href: "cup_records.html", label: "Cup Records" },
  ],
});
