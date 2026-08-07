/** Site navigation map (full menus after you have a club) */

export const SECTION_NAVIGATION = {
  id: "navigation",
  title: "Navigation",
  blocks: [
    {
      type: "p",
      html: `After you have a club, the top menu groups pages by job. Pin favourites on the
        <a href="dashboard.html">Dashboard</a>. Before a club, you only see <b>The Waiting Room</b>
        (see <a href="#waiting-room">above</a>).`,
    },
    { type: "h3", html: "Transfers — Players" },
    {
      type: "links",
      items: [
        { href: "GPDB.html", label: "Player Database (GPDB)" },
        { href: "all_listings.html", label: "Transfer Market" },
        { href: "draftauction.html", label: "Player Draft Auctions" },
        { href: "legacy_players.html", label: "Legacy Players" },
        { href: "expiring_contracts.html", label: "Expiring Contracts" },
        { href: "season_transfers.html", label: "Seasons Player Transfers" },
      ],
    },
    { type: "h3", html: "Managers" },
    {
      type: "links",
      items: [
        { href: "MGDB.html", label: "Manager Database" },
        { href: "manager_listings.html", label: "Manager Market" },
        { href: "manager_draftauction.html", label: "Manager Draft Auction" },
        { href: "season_manager_transfers.html", label: "Seasons Manager Transfers" },
      ],
    },
    { type: "h3", html: "Clubs" },
    {
      type: "links",
      items: [
        { href: "club_database.html", label: "Club Database" },
        { href: "club_auction.html", label: "Club Auction" },
        { href: "season_club_purchases.html", label: "Season Club Purchases" },
      ],
    },
    { type: "h3", html: "League &amp; cups" },
    {
      type: "links",
      items: [
        { href: "clubs.html", label: "Clubs" },
        { href: "fixtures.html", label: "Fixtures" },
        { href: "progress.html", label: "Tables" },
        { href: "league_stats.html", label: "Stats" },
        { href: "challenges.html", label: "Season challenges" },
        { href: "cups.html?cup=league_cup", label: "League Cup" },
        { href: "cups.html?cup=super8", label: "Super8" },
        { href: "cups.html?cup=plate", label: "Plate" },
        { href: "cups.html?cup=shield", label: "Shield" },
        { href: "cups.html?cup=bowl", label: "Bowl" },
        { href: "world_cup.html", label: "World Cup" },
      ],
    },
    { type: "h3", html: "My Club" },
    {
      type: "links",
      items: [
        { href: "club_details.html", label: "Club Details" },
        { href: "boardroom.html", label: "Boardroom" },
        { href: "owner_details.html", label: "Owner Details" },
        { href: "finances.html", label: "Finances" },
        { href: "squad.html", label: "Squad" },
        { href: "history.html", label: "Club History" },
        { href: "stadium.html", label: "Stadium" },
        { href: "matchday.html", label: "Match Day" },
        { href: "transfer_center.html", label: "Transfer Centre" },
      ],
    },
    { type: "h3", html: "My Nation" },
    {
      type: "links",
      items: [
        { href: "national_team.html", label: "National team" },
        { href: "nation_select.html", label: "Nation selection" },
        { href: "nation_player_pool.html", label: "Nation player pool" },
        { href: "world_cup.html", label: "World Cup" },
      ],
    },
    { type: "h3", html: "Owners" },
    {
      type: "links",
      items: [
        { href: "learning_gpsl.html", label: "Learning GPSL" },
        { href: "waiting_list.html", label: "Waiting list" },
        { href: "owner_rankings.html", label: "Owner rankings" },
        { href: "challenges.html", label: "Season challenges" },
        { href: "inbox.html", label: "Inbox" },
      ],
    },
  ],
};
