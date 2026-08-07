/** My Club pages overview */

export const SECTION_MY_CLUB = {
  id: "my-club",
  title: "My Club pages",
  blocks: [
    {
      type: "ul",
      items: [
        `<b><a href="club_details.html">Club Details</a></b> — badge, division, nation, kits, dashboard colours, and club overview.`,
        `<b><a href="boardroom.html">Boardroom</a></b> — prestige expectations, season delivery, manager deal (renew / list / sack), and government subsidies (HG / Youth / Weak squad).`,
        `<b><a href="owner_details.html">Owner Details</a></b> — login email/password, Discord owner tag, profile badge, <b>match availability</b>, timezone, and <b>holiday booking</b>
          (before you have a club, set tag / timezone / availability on <a href="awaiting_club.html">Owner details</a> in The Waiting Room).`,
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
};

export const SECTION_FINANCES = {
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
        `<b>Government subsidies</b> — HG, Youth, and B&amp;B targets on <a href="boardroom.html">Boardroom</a>; payments appear in season accounts when earned.`,
        `<b>Season accounts</b> — workbook-style view: <b>Posted</b> (ledger total this season), <b>Breakdown</b> by type, <b>Running total</b>, and <b>Pending</b> (forecast not yet on the ledger). Projected balance = current + pending.`,
      ],
    },
    {
      type: "tip",
      html: `Fines, cup prizes, challenge payouts, and transfer fees all arrive as inbox messages and ledger lines.`,
    },
  ],
};

export const SECTION_EXPECTATIONS = {
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
};
