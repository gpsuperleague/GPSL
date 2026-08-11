/** Transfers, markets, auctions & drafts */

export const SECTION_TRANSFERS = {
  id: "transfers",
  title: "Transfers &amp; markets",
  blocks: [
    {
      type: "links",
      items: [
        { href: "transfer_center.html", label: "Transfer Centre" },
        { href: "all_listings.html", label: "Transfer Market" },
        { href: "season_transfers.html", label: "Season Transfers" },
        { href: "season_club_purchases.html", label: "Season Club Purchases" },
      ],
    },
    { type: "h3", html: "Transfer window" },
    {
      type: "ul",
      items: [
        `When the <b>transfer window</b> is open, list players from the squad or Transfer Centre, bid on <a href="all_listings.html">Transfer Market</a> listings, and accept or reject direct offers.`,
        `Completed deals post to finances and appear in your <a href="inbox.html">Inbox</a>.`,
        `<b>Scouting targets</b> — save players from GPDB; review them under Transfer Centre → Scouting Targets.`,
        `<b>Legacy cards</b> — players removed from pesdb.net stay at their club but cannot be sold; see <a href="#squad">Squad &amp; contracts</a> and <a href="legacy_players.html">Legacy players</a>.`,
      ],
    },
    { type: "h3", html: "Selling abroad" },
    {
      type: "ul",
      items: [
        `Limited <b>foreign club</b> sale slots per season — using one avoids the squad overflow fine when you need to free a place.`,
        `Check squad warnings before confirming any signing or winning bid.`,
      ],
    },
    { type: "h3", html: "Underperformance listings" },
    {
      type: "ul",
      items: [
        `If a big or medium club misses its season expectation, a player may be <b>forced onto the market</b> at MV with perpetual relisting — you cannot delist them.`,
        `Full rules: <a href="#club-expectations">Big &amp; medium club expectations</a>.`,
      ],
    },
  ],
};

export const SECTION_AUCTIONS = {
  id: "auctions",
  title: "Auctions &amp; drafts",
  blocks: [
    {
      type: "warn",
      html: `<b>Important:</b> Club auction, player draft, and manager draft are <b>independent</b>.
        Admin enables each one separately. A countdown on a page only appears when that auction type is active —
        enabling club auction does not turn on player or manager draft timers elsewhere.`,
    },
    { type: "h3", html: "Club draft auction (get a club)" },
    {
      type: "links",
      items: [
        { href: "awaiting_club.html", label: "Owner details" },
        { href: "club_auction.html", label: "Auction room" },
        { href: "waiting_list.html", label: "Waiting list" },
      ],
    },
    {
      type: "ul",
      items: [
        `For owners <b>without a club</b> who have been invited from the waiting list. Full prep rules: <a href="#waiting-room">The Waiting Room</a>.`,
        `Highest bidder wins when the window closes and settlement runs. Winning bid is charged; remaining budget becomes your club balance.`,
      ],
    },
    { type: "h3", html: "Player draft auction" },
    {
      type: "links",
      items: [
        { href: "GPDB.html", label: "GPDB" },
        { href: "draftauction.html", label: "Draft auction list" },
      ],
    },
    {
      type: "ul",
      items: [
        `Timed window: opens <b>Day 1 19:00 UK</b>, bids until Day 2 18:00, then a secret random finish between 18:50 and 18:59 — the countdown never shows the exact finish time in advance.`,
        `<b>Draft credits</b> limit how many players you can win. Favourite listings on GPDB for quick access.`,
        `Highest bid wins each player when the draft settles. Optional <b>max bid</b> auto-raises by the min step when you are outbid.`,
        `Do <b>not</b> open or min-step probe auctions just to force rivals’ max/auto-bids upward — that is against fair play.`,
      ],
    },
    { type: "h3", html: "Manager draft auction" },
    {
      type: "links",
      items: [
        { href: "MGDB.html", label: "MGDB" },
        { href: "manager_draftauction.html", label: "Manager draft list" },
      ],
    },
    {
      type: "ul",
      items: [
        `Same schedule pattern as player draft when enabled (Day 1 19:00 UK start, secret random finish on Day 2).`,
        `You may only <b>lead one</b> manager auction at a time — finish or get outbid before bidding elsewhere.`,
        `Open a free agent from <a href="MGDB.html">MGDB</a> to start their draft thread, or bid from the <a href="manager_draftauction.html">Manager draft list</a>.`,
        `Clubs that <b>already have a manager</b> cannot win a draft listing — settle by sacking/transferring first if you need a new boss.`,
        `After the random finish, winners are assigned automatically within about a minute — check <a href="club_details.html">Club Details</a> for your new manager. The draft list clears once settlement runs.`,
      ],
    },
    { type: "h3", html: "Special auctions" },
    {
      type: "links",
      items: [{ href: "special_auction.html", label: "Special Auction" }],
    },
    {
      type: "ul",
      items: [
        `Occasional league events (e.g. lowest unique bid, snap auction) for cash or player prizes. Appears in the nav when live.`,
      ],
    },
  ],
};
