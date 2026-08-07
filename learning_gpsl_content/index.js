/**
 * Learning GPSL — composed handbook sections.
 * Edit individual modules; this file only assembles order + intro meta.
 */

import { SECTION_WAITING_ROOM } from "./waiting_room.js";
import { SECTION_NAVIGATION } from "./navigation.js";
import {
  SECTION_MY_CLUB,
  SECTION_FINANCES,
  SECTION_EXPECTATIONS,
} from "./club_pages.js";
import { SECTION_SQUAD, SECTION_MANAGERS } from "./squad_managers.js";
import { SECTION_TRANSFERS, SECTION_AUCTIONS } from "./transfers_auctions.js";
import {
  SECTION_MATCH_SCHEDULING,
  SECTION_MATCHDAY,
} from "./fixtures_results.js";
import { SECTION_LEAGUE, SECTION_INTERNATIONAL } from "./league_world.js";
import {
  SECTION_OWNERS,
  SECTION_CENTRAL_BANK,
  SECTION_SEASON,
  SECTION_RECENT,
  SECTION_HELP,
} from "./reference.js";

export const LEARNING_GPSL_META_HTML = `A guide for new and returning owners — how the site works, where to go, and the main league rules
  you need day to day. <b>No club yet?</b> Start with
  <a href="#waiting-room">The Waiting Room</a>, your
  <a href="waiting_list.html">waiting list</a> place, and
  <a href="awaiting_club.html">Owner details</a>.
  Once you have a club, most actions start from your
  <a href="inbox.html">Inbox</a> or the <a href="dashboard.html">Dashboard</a>.`;

/** @type {{ id: string, title: string, blocks: object[] }[]} */
export const LEARNING_GPSL_SECTIONS = [
  SECTION_WAITING_ROOM,
  SECTION_NAVIGATION,
  SECTION_MY_CLUB,
  SECTION_FINANCES,
  SECTION_EXPECTATIONS,
  SECTION_SQUAD,
  SECTION_MANAGERS,
  SECTION_TRANSFERS,
  SECTION_AUCTIONS,
  SECTION_MATCH_SCHEDULING,
  SECTION_MATCHDAY,
  SECTION_LEAGUE,
  SECTION_INTERNATIONAL,
  SECTION_OWNERS,
  SECTION_CENTRAL_BANK,
  SECTION_SEASON,
  SECTION_RECENT,
  SECTION_HELP,
];
