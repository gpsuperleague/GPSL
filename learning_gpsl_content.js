/**
 * Learning GPSL — owner handbook copy (modular sections).
 * Edit text here; learning_gpsl.js renders it into #learningGuide.
 */

export const LEARNING_GPSL_META_HTML = `A guide for new and returning owners — how the site works, where to go, and the main league rules
      you need day to day. Most actions start from your <a href="inbox.html">Inbox</a> or the
      <a href="dashboard.html">Dashboard</a>.`;

/** @type {{ id: string, title: string, blocks: object[] }[]} */
export const LEARNING_GPSL_SECTIONS = [
  {
    id: "getting-started",
    title: "Getting started &amp; club auction",
    blocks: [
      {
        type: "p",
        html: `Before you have a club, the site is limited to registration and the <b>club auction</b>.
        Admin registers your login; you choose an <b>owner tag</b> (your public name on rankings and
        auction leader boards) and bid on a vacant club from your starting budget.`,
      },
      {
        type: "links",
        items: [
          { href: "awaiting_club.html", label: "Club auction (registration)" },
          { href: "club_auction.html", label: "Club auction room" },
          { href: "login.html", label: "Login" },
        ],
      },
      { type: "h3", html: "Rules" },
      {
        type: "ul",
        items: [
          `<b>Owner tag</b> — set on <a href="awaiting_club.html">registration</a> before bidding.
          It is shown as the auction leader and on owner rankings. <b>It cannot be changed</b> once saved for the club auction.`,
          `<b>Starting budget</b> — you bid from a league-set balance (currently ₿550m for new owners). Winning bid is deducted when the club is assigned; the remainder becomes your club balance.`,
          `<b>Opening bids</b> — based on club prestige and stadium capacity (stadium cost = capacity × ₿1,000). Check capacity, expected Season 1 position, gate income, and maintenance on the auction page before you bid.`,
          `<b>Countdown</b> — club auction uses the same timed window as draft auctions (Day 1 19:00 UK start). The timer only appears on club auction pages when the club auction is enabled — not on player or manager draft pages.`,
          `After you win, your club is linked to your account, finances are set, and the full site opens.`,
        ],
      },
      {
        type: "tip",
        html: `Read this guide while you wait. Once you have a club, your badge appears top-left in the nav and links to <a href="club_details.html">Club Details</a>.`,
      },
    ],
  },

  {
    id: "navigation",
    title: "Navigation",
    blocks: [
      {
        type: "p",
        html: `The top menu groups pages by what you are doing. Pin favourites on the <a href="dashboard.html">Dashboard</a> for quick access.`,
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
          { href: "owner_rankings.html", label: "Owner rankings" },
          { href: "challenges.html", label: "Season challenges" },
          { href: "inbox.html", label: "Inbox" },
        ],
      },
    ],
  },

  {
    id: "my-club",
    title: "My Club pages",
    blocks: [
      {
        type: "ul",
        items: [
          `<b><a href="club_details.html">Club Details</a></b> — badge, division, nation, government subsidy cards (HG / Youth / B&amp;B), kits, dashboard colours, and club overview.`,
          `<b><a href="boardroom.html">Boardroom</a></b> — club prestige expectations, season delivery, and manager deal (renew / list / sack).`,
          `<b><a href="owner_details.html">Owner Details</a></b> — login email/password, Discord owner tag, profile badge, <b>match availability</b> (weekly calendar), and <b>holiday booking</b>.`,
          `<b><a href="squad.html">Squad</a></b> — registered players, home-grown and under-21 counts, contracts, list/sell actions.`,
          `<b><a href="finances.html">Finances</a></b> — current balance and links to ledger, income, costs, and season accounts.`,
          `<b><a href="stadium.html">Stadium</a></b> — capacity, attendance estimate, upcoming home gates, expansion.`,
          `<b><a href="matchday.html">Match Day</a></b> — submit scores, player stats, and your match squad (after kick-off is agreed and both owners have checked in).`,
          `<b><a href="transfer_center.html">Transfer Centre</a></b> — your listings, incoming offers, scouting targets, and direct deals.`,
          `<b><a href="history.html">Club History</a></b> — past seasons, positions, archived results, and a <b>trophy cabinet</b> (click a trophy for that season’s final table or cup bracket).`,
          `<b><a href="fixtures.html">Fixtures</a></b> — your games highlighted; <b>Propose time</b> / <b>Respond</b> opens the scheduling page for that match.`,
        ],
      },
    ],
  },

  {
    id: "finances",
    title: "Finances",
    blocks: [
      {
        type: "links",
        items: [
          { href: "finances.html", label: "Overview" },
          { href: "finances_ledger.html", label: "Ledger" },
          { href: "finances_incoming.html", label: "Posted income" },
          { href: "finances_outgoing.html", label: "Posted costs" },
          { href: "finances_accounts.html", label: "Season accounts" },
        ],
      },
      { type: "h3", html: "How money moves" },
      {
        type: "ul",
        items: [
          `<b>Balance</b> — your spendable club cash. Transfers, wages, fines, and prizes all post here via the ledger.`,
          `<b>Gate receipts</b> — league home matches: 100% to the home club. Formula: capacity × fill rate × <b>₿20/seat</b>. Fill depends on table position and recent history. Cup ties split 50/50.`,
          `<b>Stadium maintenance</b> — seasonal cost based on capacity (12.5% × capacity × ₿1,500). Shown on <a href="stadium.html">Stadium</a> and in season accounts.`,
          `<b>Government subsidies</b> — HG, Youth, and B&amp;B targets on <a href="club_details.html">Club Details</a>; payments appear in season accounts when earned.`,
          `<b>Season accounts</b> — workbook-style view: <b>Posted</b> (ledger total this season), <b>Breakdown</b> by type, <b>Running total</b>, and <b>Pending</b> (forecast not yet on the ledger). Projected balance = current + pending.`,
        ],
      },
      {
        type: "tip",
        html: `Fines, cup prizes, challenge payouts, and transfer fees all arrive as inbox messages and ledger lines.`,
      },
    ],
  },

  {
    id: "club-expectations",
    title: "Big &amp; medium club expectations",
    blocks: [
      {
        type: "p",
        html: `Clubs are ranked by <b>prestige</b> (top 10 = <b>big</b>, 11–35 = <b>medium</b>, rest = <b>low</b>).
        Each season the league compares your <b>expected</b> performance (from prestige rank and, for medium/low clubs, manager rating)
        to your <b>actual</b> league finish and cup results. See <a href="stadium.html">Stadium</a> for fill targets and performance bands
        (on target / slight / bad / abysmal).`,
      },
      { type: "h3", html: "What “expectation” means" },
      {
        type: "ul",
        items: [
          `<b>Expected position</b> — derived from prestige rank (better clubs are expected to finish higher).`,
          `<b>Medium &amp; low clubs</b> — a strong manager rating can <em>raise</em> the expectation (you are expected to finish closer to the top).`,
          `<b>Big clubs</b> — manager rating does not lower the bar; big clubs are always held to a high standard.`,
          `Missing expectation also affects <b>stadium gate fill</b> and can trigger attendance penalties — not only player unrest.`,
        ],
      },
      { type: "h3", html: "Player transfer request (if you miss the target)" },
      {
        type: "p",
        html: `Checked at <b>season archive</b> (end of season). At most <b>one</b> forced listing per club per season.`,
      },
      {
        type: "ul",
        items: [
          `<b>Big clubs</b> — one random player from your <b>top four rated</b> squad members requests a transfer.
          Any age. Listed at <b>market value</b> on the <a href="all_listings.html">Transfer Market</a>.`,
          `<b>Medium clubs</b> — same rule, but only players rated <b>74–78</b> who are <b>over 21</b> (22 or older) can be chosen.`,
          `<b>Low clubs</b> — no underperformance transfer requests.`,
        ],
      },
      { type: "h3", html: "Forced listing rules" },
      {
        type: "ul",
        items: [
          `<b>Reserve = market value</b> — buyers bid at least MV; normal transfer window rules apply to purchasers.`,
          `<b>Perpetual relisting</b> — if the listing window closes with no sale, it reopens automatically at the <em>current</em> market value.`,
          `<b>Cannot remove</b> — you cannot cancel or “Remove” the listing from <a href="transfer_center.html">Transfer Centre</a>.`,
          `<b>Below reserve</b> — if a bid is below MV you may still accept; you cannot reject a forced listing back off the market (it relists instead).`,
          `Normal same-season and final-year listing blocks are <b>waived</b> for these forced requests — the player is pushing to leave.`,
          `You get an <a href="inbox.html">Inbox</a> message naming the player and linking to Transfer Centre.`,
        ],
      },
      {
        type: "warn",
        html: `This is separate from <b>manager retention</b> (manager released if league target missed) — you can face both in the same season.
        See <a href="boardroom.html">Boardroom</a> and <a href="#managers">Managers</a> below.`,
      },
      {
        type: "links",
        items: [
          { href: "boardroom.html", label: "Boardroom" },
          { href: "stadium.html", label: "Stadium (expectations)" },
          { href: "club_details.html", label: "Club Details" },
          { href: "transfer_center.html", label: "Transfer Centre" },
          { href: "all_listings.html", label: "Transfer Market" },
          { href: "inbox.html", label: "Inbox" },
        ],
      },
    ],
  },

  {
    id: "squad",
    title: "Squad &amp; contracts",
    blocks: [
      {
        type: "p",
        html: `Rules are enforced when you sign players — warnings appear before you bid or confirm.`,
      },
      { type: "h3", html: "Squad size &amp; composition" },
      {
        type: "ul",
        items: [
          `<b>Maximum 28</b> registered players. You can still bid at 28, but a 29th signing triggers an automatic release of your highest-rated player who was <em>not</em> signed this season.`,
          `If a foreign sale slot is available, that route is used (no fine). Otherwise the player is released for market value, your club is fined <b>₿10,000,000</b>, and the player cannot be signed until next season.`,
          `<b>Home-grown</b> — minimum <b>8</b> players whose nation matches your club nation.`,
          `<b>Under-21</b> — minimum <b>5</b> players aged 21 or younger.`,
          `<b>Star players</b> — automatic from rating (OooO excluded from the cap). Super League max <b>3</b>, Championship max <b>2</b>.`,
          {
            html: `<b>August enforcement</b> — from GPSL August, clubs still short on size / HG / U21, or over the star cap, are auto-fixed once:`,
            children: [
              `<b>₿2.5m fine</b> per missing player (or per star released) + <b>₿2.5m</b> season-loan fee when a loan is issued.`,
              `Emergency loans are rating <b>≤72</b>, prefer home-grown, else any nation; picks favour positional gaps (2 GK / 8 DEF / 8 MID / 6 ATT) for the loan only.`,
              `At 28 players, lowest eligible players are released (100% MV) to make room — never HG when fixing HG, never U21 when fixing U21, and <b>never OooO</b>.`,
              `Over the star cap: lowest-rated stars released at <b>125% MV</b> + ₿2.5m fine each (OooO protected); if that would drop under 24, a loan is taken first.`,
              `Released players are unavailable for auction until next season.`,
            ],
          },
        ],
      },
      { type: "h3", html: "Contracts (summary)" },
      {
        type: "ul",
        items: [
          `Standard contracts run in <b>3-season</b> cycles. Track expiry on <a href="expiring_contracts.html">Expiring Contracts</a> and the squad page.`,
          `<b>Final season</b> — you cannot list or sell the player on the transfer market. They enter the hidden wage auction at expiry (all clubs, including yours, may bid once) — unless they are a <b>legacy card</b> (see below).`,
          `<b>Home-grown ≤23</b> — protected from the expiry auction; uncontested renewal applies while still eligible. Protection ends at age 24.`,
          `Winning an expiry bid gives a new 3-season contract at the bid wage from season rollover.`,
        ],
      },
      { type: "h3", html: "Legacy cards (off PESDB)" },
      {
        type: "p",
        html: `When admin syncs GPDB with <a href="https://pesdb.net/efootball/" target="_blank" rel="noopener">pesdb.net</a>,
        players still in GPSL but no longer on the site are marked <b>legacy</b>. They stay at their club and remain playable.`,
      },
      {
        type: "ul",
        items: [
          `<b>Cannot be sold or listed</b> on the transfer market at any time.`,
          `<b>Not on the expiring-contracts wage bid market</b> — other clubs cannot bid for them.`,
          `In the <b>final contract year</b>, renew from <a href="squad.html">Squad</a>: <b>one season at a time</b> (not a new 3-year deal). Home-grown ≤23 may keep the same wage on renew.`,
          `Or choose <b>Expire — release for MV</b> from Squad to drop the player for market value.`,
          `If the card returns on a future sync, it becomes a normal GPDB card again.`,
        ],
      },
      {
        type: "links",
        items: [{ href: "legacy_players.html", label: "Legacy players (league list)" }],
      },
      {
        type: "links",
        items: [
          { href: "squad.html", label: "Squad" },
          { href: "expiring_contracts.html", label: "Expiring Contracts" },
          { href: "GPDB.html", label: "Player Database" },
          { href: "player_career.html", label: "Player career" },
        ],
      },
    ],
  },

  {
    id: "managers",
    title: "Managers",
    blocks: [
      {
        type: "links",
        items: [
          { href: "MGDB.html", label: "Manager Database" },
          { href: "manager_listings.html", label: "Manager Market" },
          { href: "manager_draftauction.html", label: "Manager Draft Auction" },
        ],
      },
      {
        type: "ul",
        items: [
          `Each club has one manager. Their <b>rating</b> and your <b>division</b> set a league finish target for the season.`,
          `Miss the target and the manager may be released at season end (see inbox / season rollover messages).`,
          `Missing expectations can also trigger a <b>player transfer request</b> on big and medium clubs — see <a href="#club-expectations">Big &amp; medium club expectations</a>.`,
          `<b>List / sack</b> — available in <b>June, July, and January</b> (not August — fixtures have started). From Squad or Club Details. Sack pays half market value (once per season).`,
          `<b>No instant sack</b> — you cannot sack until mid-spell: summer signing → first chance in <b>January</b>; January signing → first chance next <b>June–July</b>.`,
          `<b>August without a manager</b> — you may still hire from the <a href="manager_listings.html">Manager Transfer Market</a> / FA board, but you <b>cannot arrange kick-offs, check in, or play fixtures</b> until a manager is signed.`,
          `<b>Manager Market FA board</b> — at the start of each of those four months, <b>10 random free-agent</b> managers are listed (rating mix). Unsold ones from the previous month are cleared. Bid like a normal listing; fee goes to the league (no seller club). <b>Clubs that already have a manager cannot bid</b> (sack or transfer first).`,
          `Manager draft auctions use the same timed window as player drafts but are controlled by a <b>separate enable flag</b> — only active when admin turns on the manager draft.`,
          `When the random finish passes, winning bids are settled automatically (manager assigned, fee debited). If a club already has a manager, that auction closes without a transfer.`,
          `Season expectations message arrives in your <a href="inbox.html">Inbox</a> when a manager is signed.`,
        ],
      },
    ],
  },

  {
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
  },

  {
    id: "auctions",
    title: "Auctions &amp; drafts",
    blocks: [
      {
        type: "warn",
        html: `<b>Important:</b> Club auction, player draft, and manager draft are <b>independent</b>.
        Admin enables each one separately. A countdown on a page only appears when that auction type is active —
        enabling club auction does not turn on player or manager draft timers elsewhere.`,
      },
      { type: "h3", html: "Club auction (pre-launch)" },
      {
        type: "links",
        items: [
          { href: "awaiting_club.html", label: "Registration" },
          { href: "club_auction.html", label: "Auction room" },
        ],
      },
      {
        type: "ul",
        items: [
          `Clubs without a manager only — if you already have one, bidding is blocked until you sack or transfer them. Highest bidder wins when the window closes and admin/engine settles.`,
          `Winning bid is charged; remaining budget becomes your club balance.`,
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
          `Highest bid wins each player when the draft settles.`,
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
  },

  {
    id: "match-scheduling",
    title: "Match scheduling",
    blocks: [
      {
        type: "p",
        html: `League fixtures are published when the season starts. You and your opponent must <b>agree a kick-off</b>
        before playing. Set weekly availability on <a href="owner_details.html">Owner Details</a>, then use
        <a href="fixtures.html">Fixtures</a> → <b>Schedule</b> (or <a href="inbox.html">Inbox</a>) to propose or respond.`,
      },
      {
        type: "links",
        items: [
          { href: "owner_details.html", label: "Owner Details (availability)" },
          { href: "fixtures.html", label: "Fixtures" },
          { href: "fixture_schedule.html", label: "Schedule page" },
          { href: "inbox.html", label: "Inbox" },
        ],
      },
      { type: "h3", html: "GPSL month (Fri 19:00 UK → Fri 19:00 UK)" },
      {
        type: "ul",
        items: [
          `One real-world week = one <b>GPSL month</b> (August–May league/cup, then <b>Playoffs</b>). The nav badge shows the active month.`,
          `<b>Arrange</b> — you can agree a time from when fixtures exist (including pre-season). For an <b>September</b> fixture, the primary deadline is to have it arranged before <b>August</b> closes.`,
          `<b>Play</b> — the match should be played in its fixture GPSL month. If it passes still unplayed, it becomes a <b>catch-up</b> fixture (highlighted on Fixtures) and can be played in a later month.`,
        ],
      },
      { type: "h3", html: "1 — Availability" },
      {
        type: "ul",
        items: [
          `<b>Club Details → Edit weekly availability</b> — 30-minute blocks (UK time) Mon–Sun when you are usually free.`,
          `Set your <b>timezone</b> so kick-off times show in your local clock on the schedule page.`,
          `<b>Holidays</b> (up to 14 days/season) block availability and unlock early arrange/play for overlapping GPSL months (e.g. book Aug–Sep holiday in June → play those fixtures in June/July). Both clubs need a full squad (min 24). Book only <b>before</b> that GPSL month opens. Cancel/amend while still upcoming; after it starts, admin manages via Season Management → Owner holidays.`,
        ],
      },
      { type: "h3", html: "2 — Agree a time" },
      {
        type: "ul",
        items: [
          `<b>Home club proposes first</b> — pick a <b>mutual</b> slot (both calendars intersect in the proposal window).`,
          `Away owner gets an <a href="inbox.html">Inbox</a> message — <b>Accept</b> or counter-propose another mutual slot.`,
          `After two proposals each, the site suggests agreeing on <b>Discord</b>, then picking a slot on the schedule page.`,
          `<b>Response deadlines</b> apply while negotiating — the site tracks overdue turns during the month. <b>Missed response fines (default ₿2.5m)</b> are assessed when that fixture’s <b>play GPSL month locks</b>, not instantly mid-week.`,
        ],
      },
      { type: "h3", html: "3 — Check in &amp; play" },
      {
        type: "ul",
        items: [
          `At the <b>agreed kick-off</b>, both owners open the <b>schedule page</b> and <b>Check in</b> within <b>10 minutes</b>.`,
          `When both have checked in, <b>Enter result on Match Day</b> unlocks for that 30-minute block.`,
          `<b>Both miss check-in</b> — no fine. Use <b>Pick new time to play this month</b> on the schedule page (does not use your reschedule allowance), agree a new slot, and check in at the new kick-off.`,
          `<b>One checks in, one misses</b> — the site records a no-show but does <b>not</b> forfeit instantly. If you still play and confirm a normal result, <b>no no-show fine</b>. If the play month ends still unplayed, the no-show club gets <b>3–0 forfeit + ₿5m fine</b> at month lock.`,
          `<b>Voluntary drop</b> (≥24h before kick-off) — uses your <b>one reschedule per GPSL month</b>; returns to scheduling with no forfeit.`,
          `<b>Emergency drop</b> (&lt;24h before kick-off) — uses <b>one of two per season</b>; if you have none left, you forfeit <b>3–0</b> and a fine.`,
          `<b>Mutual override</b> — either club can request <b>play now</b> or a <b>new time</b> before the agreed kick-off; both must confirm in Inbox.`,
        ],
      },
      { type: "h3", html: "4 — Catch-up" },
      {
        type: "ul",
        items: [
          `If a league fixture’s play month closes still <b>unplayed</b>, it is flagged <b>catch-up</b> on Fixtures.`,
          `Propose new times in the <b>current</b> GPSL month window; stale agreed kick-offs can be reset without using the monthly reschedule allowance.`,
        ],
      },
      { type: "h3", html: "Scheduling fines (league — assessed at month lock)" },
      {
        type: "ul",
        items: [
          `<b>Match Management (₿10m)</b> — home never proposed by the arrangement deadline; can repeat each month until a proposal is made.`,
          `<b>Late arrangement (₿5m)</b> — first home proposal in the last 24h before the play month opens (either/or with Match Management at that lock).`,
          `<b>Missed response (₿2.5m)</b> — still negotiating with an overdue response when the play month locks.`,
          `<b>No-show at agreed kick-off (₿5m + 3–0)</b> — one club checked in, the other did not, and the match never received a normal result before month lock.`,
        ],
      },
      {
        type: "tip",
        html: `Fines post to your balance and appear in <a href="inbox.html">Inbox</a>. Admins can apply compensation for site errors — contact league admin on Discord if something looks wrong.`,
      },
      { type: "h3", html: "Inbox messages" },
      {
        type: "ul",
        items: [
          `<b>Match time proposed / countered</b> — Accept from Inbox or open Schedule to counter.`,
          `<b>Match time agreed</b> — check in at kick-off.`,
          `<b>Reschedule / replay / catch-up reset</b> — opponent reopened scheduling; home proposes again.`,
          `<b>Fine applied / compensation</b> — scheduling or matchday tariff; see note for fixture and reason.`,
        ],
      },
    ],
  },

  {
    id: "matchday",
    title: "Match day &amp; results",
    blocks: [
      {
        type: "links",
        items: [
          { href: "matchday.html", label: "Match Day" },
          { href: "fixtures.html", label: "Fixtures" },
        ],
      },
      {
        type: "ul",
        items: [
          `Each real-world week (Fri 19:00 UK → Fri 19:00 UK) is one <b>GPSL month</b> — see the calendar badge in the nav.`,
          `You need an <b>agreed kick-off</b> and <b>both check-ins</b> before you can enter a result (see <a href="#match-scheduling">Match scheduling</a>). If you missed check-in, use <b>Pick new time to play this month</b> on the schedule page first.`,
          `<b>Catch-up</b> fixtures (play month passed, still unplayed) can be submitted in a later active GPSL month once re-scheduled.`,
          `Submit scores and player stats on <a href="matchday.html">Match Day</a>. Set your <b>match squad</b> (11 starters + subs) on the pitch tab; starters auto-tick in the stats table.`,
          `Your opponent confirms or rejects — you are notified at each step via the inbox.`,
          `<b>League:</b> win 3 pts, draw 1, loss 0. <b>Cup ties</b> cannot end in a draw — play extra time / penalties if needed.`,
          `Confirmed results post gate receipts (where applicable) and update tables, stats, and challenges.`,
          `If you booked a <b>holiday</b> overlapping the GPSL month, you may arrange and play that fixture early during the current GPSL week (including pre-season June/July) — both clubs need min 24 players. The result is saved, but <b>league table and player stats wait</b> until that GPSL month becomes active. See <a href="owner_details.html">Owner Details</a>.`,
        ],
      },
    ],
  },

  {
    id: "league",
    title: "League &amp; cups",
    blocks: [
      {
        type: "p",
        html: `60 clubs: <b>SuperLeague</b> (20) plus two <b>Championship</b> divisions (20 each). Promotion, relegation, and playoffs follow the pyramid rules on the tables page.`,
      },
      {
        type: "links",
        items: [
          { href: "progress.html", label: "Tables" },
          { href: "fixtures.html", label: "Fixtures" },
          { href: "league_stats.html", label: "Stats" },
          { href: "clubs.html", label: "Clubs" },
          { href: "cups.html", label: "Cup brackets" },
        ],
      },
      { type: "h3", html: "Cups" },
      {
        type: "ul",
        items: [
          `<b>League Cup</b> — 60-club knockout. <b>Prestige cups</b> (Super8, Plate, Shield, Bowl) qualify from league standings.`,
          `Cup round fees and prizes post to both clubs when matches are confirmed.`,
          `<b>World Cup</b> — national teams; owner nations draft in ranking order (see International).`,
        ],
      },
    ],
  },

  {
    id: "international",
    title: "Nation &amp; World Cup",
    blocks: [
      {
        type: "links",
        items: [
          { href: "nation_select.html", label: "Nation selection" },
          { href: "national_team.html", label: "National team" },
          { href: "world_cup.html", label: "World Cup" },
        ],
      },
      {
        type: "ul",
        items: [
          `When the selection window opens, owners pick a national team in <b>owner ranking</b> order (rolling four-season points).`,
          `You receive an inbox message when it is <b>your turn</b> — use <a href="nation_select.html">Nation selection</a> to claim a nation.`,
          `Manage squads and fixtures on <a href="national_team.html">National team</a>. World Cup cycles add extra ranking points for owners.`,
          `Track standing on <a href="owner_rankings.html">Owner rankings</a> (rolling, season-by-season, and all-time tabs).`,
        ],
      },
    ],
  },

  {
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
  },

  {
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
  },

  {
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
  },

  {
    id: "recent-updates",
    title: "Recent updates (2026)",
    blocks: [
      {
        type: "p",
        html: `Summary of newer features and rule changes — also woven into the sections above.`,
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
      { type: "h3", html: "Match scheduling (July 2026)" },
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
      { type: "h3", html: "Club Details" },
      {
        type: "ul",
        items: [
          `<b>Change email</b> and <b>change password</b> side by side on Club Details.`,
          `<b>Match availability</b> calendar and existing holiday booking — see <a href="#match-scheduling">Match scheduling</a>.`,
        ],
      },
      { type: "h3", html: "Navigation additions" },
      {
        type: "ul",
        items: [
          `<b>Transfers → Legacy players</b> — all legacy cards by club.`,
          `<b>Transfers → Club Auction</b> — also linked from registration when bidding for a vacant club.`,
          `<b>My Nation → Nation player pool</b> — eligible players for your national team.`,
          `<b>League → Challenges</b> — season challenge targets and prizes (also under Owners).`,
          `<b>Fixtures → Propose time / Respond</b> — per-match scheduling for your club’s games.`,
        ],
      },
    ],
  },

  {
    id: "help",
    title: "Need help?",
    blocks: [
      {
        type: "ul",
        items: [
          `Check your <a href="inbox.html">Inbox</a> first — it is the hub for anything needing action.`,
          `Use this page and the linked screens; rules on squad, finances, and match day are also shown in context where they apply.`,
          `League admins can assist with disputes, fines, account linking, and technical issues.`,
        ],
      },
    ],
  },
];
