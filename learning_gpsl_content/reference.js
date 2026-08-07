/** Rankings, bank, season rhythm, recent updates, help */

export const SECTION_OWNERS = {
  id: "owners",
  title: "Rankings &amp; challenges",
  blocks: [
    {
      type: "links",
      items: [
        { href: "owner_rankings.html", label: "Owner rankings" },
        { href: "challenges.html", label: "Season challenges" },
      ],
    },
    { type: "h3", html: "Owner rankings" },
    {
      type: "ul",
      items: [
        `Points from league position and cup runs each season. Rolling four seasons sets World Cup nation draft order.`,
        `The <b>Owner</b> column shows your <b>owner tag</b>, not the club short name.`,
      ],
    },
    { type: "h3", html: "Season challenges" },
    {
      type: "ul",
      items: [
        `Admin-set targets for the current season (e.g. goals, wins, clean sheets). Prizes post instantly when a match is confirmed.`,
        `First club to complete <b>all</b> targets in a window earns the period bonus.`,
      ],
    },
  ],
};

export const SECTION_CENTRAL_BANK = {
  id: "central-bank",
  title: "Central Bank",
  blocks: [
    {
      type: "p",
      html: `League-wide banking separate from your club balance — loans and services between owners and the league.`,
    },
    {
      type: "links",
      items: [
        { href: "central_bank.html", label: "Bank balance" },
        { href: "central_bank_loans.html", label: "League loans" },
        { href: "central_bank_counter.html", label: "Service counter" },
      ],
    },
  ],
};

export const SECTION_SEASON = {
  id: "season",
  title: "Season rhythm &amp; inbox",
  blocks: [
    {
      type: "links",
      items: [
        { href: "inbox.html", label: "Inbox" },
        { href: "dashboard.html", label: "Dashboard" },
      ],
    },
    {
      type: "ul",
      items: [
        `At month start you receive a <b>match preview</b> (opponents, form, threats).`,
        `Transfer news, fines, cup draws, nation picks, <b>match scheduling</b>, and finance postings all go to the inbox — most messages link straight to the relevant page.`,
        `End of season: awards (Golden Boot, Ballon d'Or, etc.), manager retention, archived history, and season overview messages.`,
        `Unread count appears on the Inbox nav link.`,
      ],
    },
    { type: "h3", html: "Club expectations (summary)" },
    {
      type: "ul",
      items: [
        `Strong stadium attendance — underperformance reduces gate income and can trigger penalties (<a href="stadium.html">Stadium</a>).`,
        `Big and medium clubs that miss the season target may lose a star player via a <b>forced transfer listing</b> — <a href="#club-expectations">full rules</a>.`,
        `Stay within squad limits and composition minimums (<a href="squad.html">Squad</a>).`,
        `Meet manager targets or plan for a change at season end.`,
        `Respond to inbox actions promptly (confirm results, accept deals, pick your nation when called, <b>accept or counter match times</b>).`,
      ],
    },
  ],
};

export const SECTION_RECENT = {
  id: "recent-updates",
  title: "Recent updates (2026)",
  blocks: [
    {
      type: "p",
      html: `Summary of newer features and rule changes — also woven into the sections above.`,
    },
    { type: "h3", html: "The Waiting Room" },
    {
      type: "ul",
      items: [
        `Owners without a club use a limited menu: waiting list, owner details, databases, and club draft auction.`,
        `Admin invites to auction with an <b>Auction</b> tick on the admin waiting list; untick returns them to the list.`,
        `Starting bank balance for new owners is currently <b>₿650m</b>.`,
        `Full menus unlock automatically once a club is assigned.`,
      ],
    },
    { type: "h3", html: "GPDB &amp; player values" },
    {
      type: "p",
      html: `Admin can sync the <a href="GPDB.html">Player Database</a> from pesdb.net between seasons (Season Break tools).
        After a sync, matched players get updated stats; new pesdb cards appear as free agents; missing cards become legacy.`,
    },
    {
      type: "ul",
      items: [
        `<b>Rating</b> in GPDB and squad may show as <b>85 (95)</b> — current OVR plus calculated potential used for economics.`,
        `<b>Pot.</b> column — calculated potential (league formula), not always the same as the raw pesdb max level.`,
        `<b>Market value</b> and <b>maximum reserve price</b> follow the league spreadsheet formulas (rating, potential, age, position). Maximum reserve is <b>1.5× market value</b>.`,
        `Stored values update when admin applies a sync — day-to-day screens use the database figures on listings, squad, and transfers.`,
      ],
    },
    {
      type: "links",
      items: [
        { href: "GPDB.html", label: "Player Database" },
        { href: "squad.html", label: "Squad" },
        { href: "all_listings.html", label: "Transfer Market" },
      ],
    },
    { type: "h3", html: "Legacy players" },
    {
      type: "p",
      html: `Cards that leave pesdb.net but remain in GPSL are tagged <b>legacy</b>. They still count for squad, home-grown, and match day.
        Transfer rules are restricted — full detail on <a href="legacy_players.html">Legacy players</a> and under
        <a href="#squad">Squad &amp; contracts</a>.`,
    },
    {
      type: "ul",
      items: [
        `Not sellable and not on the expiry wage auction.`,
        `Final-year renewals: <b>1 season</b> at a time from Squad.`,
        `League-wide list: Transfers → <a href="legacy_players.html">Legacy players</a>.`,
      ],
    },
    { type: "h3", html: "Match scheduling" },
    {
      type: "p",
      html: `Full rules: <a href="#match-scheduling">Match scheduling</a>. Summary — arrange from pre-season; play in the fixture month or catch up later;
        check in at kick-off; <b>fines at GPSL month lock</b> (arrangement, missed response, no-show if still unplayed).
        Missed check-in with no result? Use <b>Pick new time to play this month</b> on <a href="fixture_schedule.html">Schedule</a> — both miss = no fine.`,
    },
    { type: "h3", html: "Manager draft auto-settlement" },
    {
      type: "ul",
      items: [
        `After the Day 2 random finish, winning manager bids settle automatically (fee debited, manager assigned to club).`,
        `If the high bidder already has a manager, that listing closes without a transfer.`,
        `The <a href="manager_draftauction.html">Manager draft list</a> should clear within about a minute of finish — refresh Club Details to see your signing.`,
      ],
    },
    { type: "h3", html: "Player career honours" },
    {
      type: "ul",
      items: [
        `<a href="player_career.html">Player career</a> pages show <b>winner medals</b> (league and cup) for players who met appearance thresholds.`,
        `League medals need <b>5+</b> league apps that season; cup medals need <b>1+</b> cup appearance.`,
      ],
    },
    { type: "h3", html: "Championship Team of the Month" },
    {
      type: "ul",
      items: [
        `Separate TOTM panels for <b>Championship A</b> and <b>Championship B</b> on <a href="league_stats.html">Stats</a>, in addition to Super League TOTM.`,
      ],
    },
  ],
};

export const SECTION_HELP = {
  id: "help",
  title: "Need help?",
  blocks: [
    {
      type: "ul",
      items: [
        `If you do not have a club yet, start with <a href="#waiting-room">The Waiting Room</a> and your <a href="waiting_list.html">waiting list</a> place.`,
        `With a club, check your <a href="inbox.html">Inbox</a> first — it is the hub for anything needing action.`,
        `Use this page and the linked screens; rules on squad, finances, and match day are also shown in context where they apply.`,
        `League admins can assist with disputes, fines, account linking, and technical issues.`,
      ],
    },
  ],
};
