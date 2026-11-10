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
        { href: "scouting.html", label: "Scouting" },
        { href: "season_transfers.html", label: "Season Transfers" },
        { href: "season_club_purchases.html", label: "Season Club Purchases" },
        { href: "handpick_squad.html", label: "Handpick Squad (mid-season)" },
      ],
    },
    { type: "h3", html: "Transfer window" },
    {
      type: "ul",
      items: [
        `When the <b>transfer window</b> is open, list players from the squad or Transfer Centre, bid on <a href="all_listings.html">Transfer Market</a> listings, and accept or reject direct offers.`,
        `<b>Signing lock</b> — half a season after joining: <b>1st-half</b> signing → listable from <b>GPSL January</b>; <b>2nd-half</b> signing → listable from <b>next summer</b> (Transfer Market and foreign listing). Squad shows <b>🔒 → Jan / summer</b>. A <a href="#squad--new-owner-release">New Owner list</a> can bypass that lock. Full contract windows: <a href="#squad">Squad &amp; contracts</a>.`,
        `<b>While the window is shut</b> you can <b>list for preview</b> on players who will be sellable when it next opens. The card is view only. It becomes a normal auction when the window opens. Other clubs may <b>show interest</b>. That is not a bid and does not reserve the player.`,
        `Once a listing is active it stays up <b>at least 24 hours</b> and closes at <b>19:00 UK</b> (or the next 19:00 if those 24 hours land after 19:00).`,
        `Completed deals post to finances and appear in your <a href="inbox.html">Inbox</a>.`,
        `<b>Legacy cards</b> — players removed from pesdb.net stay at their club but cannot be sold; see <a href="#squad">Squad &amp; contracts</a> and <a href="legacy_players.html">Legacy players</a>.`,
      ],
    },
    { type: "h3", html: "Scouting &amp; Active Targets" },
    {
      type: "ul",
      items: [
        `Star players in <a href="GPDB.html">GPDB</a> to build your shortlist. Plan on <a href="scouting.html">Scouting</a> (lists + tactic boards) or Transfer Centre → Scouting.`,
        `<b>Active Targets</b> = players you are still chasing. Tick them to project spend, wages, and registration (Sq / GK / HG / U21 / ★).`,
        `Players <b>already at your club</b> are never Active Targets (shown as <b>At club</b>). Use <b>Include club squad in stats</b> to count your current squad as the baseline, and <b>Add club squad to list</b> to put them on the shortlist for planning.`,
      ],
    },
    { type: "h3", html: "Mark for sale &amp; interested clubs" },
    {
      type: "ul",
      items: [
        `From Squad / Transfer Centre you can <b>Mark for sale</b>. Clubs that have that player on their scouting shortlist show as interested.`,
        `<b>Notify interested clubs</b> (manual) — Inbox asks those owners if they want the player before you list (once per club per day).`,
        `When you actually <b>list</b> the player (Active or Pending Window), those same scout clubs get an automatic Inbox that the player is listed.`,
      ],
    },
    { type: "h3", html: "Missing / legacy cards on GPDB" },
    {
      type: "ul",
      items: [
        `If a player is missing from GPDB but on pesdb.net, use <b>Request add</b> on GPDB (Konami ID → confirm).`,
        `If a card is locked as <b>legacy</b> but you believe it should return, request an <b>unlock</b> from the same flow.`,
        `Admin reviews pending requests on GPDB sync (admins get a Staff alert). Until approved, the card stays as-is.`,
      ],
    },
    { type: "h3", html: "Selling abroad" },
    {
      type: "ul",
      items: [
        `<b>3 foreign-club slots</b> a season. Sale is at market value. The player cannot be signed in GPSL until next season. Using one avoids the squad overflow fine when you need to free a place. Details: <a href="#squad--letting-a-player-go">Letting a player go</a>.`,
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
