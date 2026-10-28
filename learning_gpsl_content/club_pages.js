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
        `<b><a href="owner_details.html">Owner Details</a></b> — login email/password, Discord owner tag, profile badge, <b>match availability</b>, timezone, <b>holiday booking</b>, and <b>season absence</b> (miss a season: fixtures awarded, finances frozen; 1 in 4) (before you have a club, set tag / timezone / availability on <a href="awaiting_club.html">Owner details</a> in The Waiting Room).`,
        `<b><a href="squad.html">Squad</a></b> — registered players, home-grown and under-21 counts, contracts, list/sell actions.`,
        `<b><a href="finances.html">Finances</a></b> — current balance and links to ledger, income, costs, and season accounts.`,
        `<b><a href="stadium.html">Stadium</a></b> — capacity, attendance estimate, upcoming home gates, expansion; also eFootball home-venue rules (licensed vs Konami stadium).`,
        `<b><a href="medical_room.html">Medical Room</a></b> — club doctor, physio ladder, specialist consult tokens (see <a href="#medical-room">Medical Room</a> in this handbook).`,
        `<b><a href="matchday.html">Match Day</a></b> — save your match squad <b>before kick-off</b> (it must be valid to check in: exactly 11 starters, 12 subs, a goalkeeper, no injured or suspended players), then submit scores and player stats once both owners have checked in; console rules include stadium setup.`,
        `<b><a href="transfer_center.html">Transfer Centre</a></b> — your listings, incoming offers, scouting targets, and direct deals.`,
        `<b><a href="history.html">Club History</a></b> — past seasons, positions, archived results, and a <b>trophy cabinet</b> (click a trophy for that season’s final table or cup bracket).`,
        `<b><a href="fixtures.html">Fixtures</a></b> — your games highlighted; <b>Propose kick-off</b> / <b>Reply to proposal</b> opens the scheduling page for that match.`,
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
        `<b>Stadium maintenance</b> — seasonal cost based on capacity (a set % × capacity × ₿1,500 — 12.5% by default, adjustable by admin). Shown on <a href="stadium.html">Stadium</a> and in season accounts.`,
        `<b>Government subsidies</b> — HG, Youth, and B&amp;B targets on <a href="boardroom.html">Boardroom</a>; payments appear in season accounts when earned.`,
        `<b>Season accounts</b> — workbook-style view: <b>Posted</b> (ledger total this season), <b>Breakdown</b> by type, <b>Running total</b>, and <b>Pending</b> (forecast not yet on the ledger). Projected balance = current + pending.`,
      ],
    },
    {
      type: "tip",
      html: `Fines, cup prizes, challenge payouts, and transfer fees all arrive as inbox messages and ledger lines.`,
    },
    { type: "h3", html: "Predicted end-of-season balance" },
    {
      type: "p",
      html: `Shown on <a href="finances.html">Finances</a>. It answers one question: <b>if nothing else happens, how much money will my club have when the season closes?</b> Click it to see the full workings.`,
    },
    {
      type: "ul",
      items: [
        `<b>Starts from your current balance</b> — the money in the bank right now.`,
        `<b>Adds what is still to come in</b> that we already know about — league home gate receipts, cup ties you are already drawn in (prize money + gate share), TV money for matches already picked, the league prize for where you sit in the table now, and subsidies you are on track for.`,
        `<b>Takes off what is still to go out</b> — player wages (after any Fan Favourite subsidy), manager salary, stadium maintenance, loan repayments due this season, and tax.`,
        `<b>Takes off your winning bids</b> — players and managers you are currently top bidder on are counted as if you win them.`,
        `<b>Leaves out anything not known yet</b> — challenge prizes, further cup runs, more TV picks, sponsor bonuses, merchandise, bank interest, player sales, fines, new signings, stadium work and FFP penalties. These are only counted once they happen.`,
      ],
    },
    {
      type: "p",
      html: `<b>What it means:</b> it is a prediction, not a promise. Early in the season most of the year is still a forecast, so the figure can move a lot. As matches are played and money is posted to the ledger, more of it becomes fact and the prediction gets more and more accurate. By Close Finances it is close to the real figure.`,
    },
    {
      type: "ul",
      items: [
        `<b>Below zero?</b> You are on course to finish in the red — you will see <b>"Short by ₿X"</b> next to your transfer budget, and the advisory transfer budget shows ₿0.`,
        `<b>At or below −₿100m</b> at Close Finances triggers an FFP fine (plus forced MV sales and a one-window buy ban), so a prediction near that line is an early warning. While the prediction sits in that band, credit rating shows <b>Watch — FFP forecast</b> with a mild loan/overdraft premium (loans are still allowed). During an FFP buy ban you still cannot transfer or sign free agents — but if fit players fall below <b>24</b>, <b>emergency loans</b> remain allowed.`,
        `The <b>advisory transfer budget</b> is the same sum without transfer sales/purchases — guidance only, it never blocks a bid.`,
      ],
    },
    {
      type: "tip",
      html: `Want to improve the figure? Sell players you don't need, trim wages, avoid fines, and go deep in the cups — every win that earns money is added the moment it is posted.`,
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
        to your <b>actual</b> league finish. See <a href="stadium.html">Stadium</a> for fill targets and performance bands
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
    { type: "h3", html: "How the season is judged" },
    {
      type: "ul",
      items: [
        `<b>Places below your expected finish</b> — level or better = <b>on target</b>; 1–2 places below = <b>slight miss</b>; 3–5 = <b>bad</b>; 6+ = <b>abysmal</b>.`,
        `<b>Super League relegation</b> — if you were expected to finish 15th or higher, being relegated (by any route) is at least a <b>bad</b> season; dropping into 18th–20th when expected top 10 is <b>abysmal</b>.`,
        `<b>Expected 16th–20th (“Avoid relegation”)</b> — staying up (15th or higher, or surviving the playoffs) is <b>on target</b>. Relegated via the playoffs, or in 18th–20th but no lower than expected = <b>slight</b>; 1–2 places lower = <b>bad</b>; 3+ = <b>abysmal</b>.`,
        `<b>Championship</b> — promotion (top 2 or playoff winner) is always <b>on target</b>.`,
        `<b>Cup backup</b> — meeting your club cup target rescues a <b>slight</b> miss only. If your target is in the Super8 but you are not in it this season, the same stage of the <b>Plate</b> counts instead.`,
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
        `<b>Big clubs</b> — slight miss: a <b>lower-rated</b> player (not your top four) requests a transfer.
          Bad/abysmal: one random player from your <b>top four rated</b>. Listed at <b>market value</b>.`,
        `<b>Medium clubs</b> — slight miss: rated <b>68–73</b> (over 21). Bad/abysmal: rated <b>74–78</b> (over 21).`,
        `<b>Low clubs</b> — a player rated <b>72 or below</b> may hand in a transfer request.`,
        `<b>Protected</b> — your <b>One of our Own</b>, <b>Fan Favourite</b>, <b>home-grown players aged 23 or under</b> and <b>non-home-grown players aged 21 or under</b> never hand in a transfer request. A protected player is skipped; if nobody else is eligible in the usual group, the request drops down to the next group (top 4 → rated 76 or below → 74–78 → 68–73 → 72 or below → anyone), so another player is listed.`,
        `<b>Board fine</b> — on a <b>club</b> expectation miss only, 10% of your personal GPSL Building Society balance can be taken (manager target misses do not trigger this).`,
        `<b>Owner salary</b> — at season end the club pays you ₿100 per 1,000 stadium seats into your Building Society wallet, only if the club met its expectation (on target, or a slight miss rescued by a cup). It's paid after any board fine.`,
        `<b>Manager deals</b> — after <b>season 1</b>, a bad or abysmal <b>club</b> miss (3+ places below expectation) means the board sacks the manager (MV credited, 2-season re-hire ban).
          At the end of the deal: miss your manager’s personal target both seasons and they leave (refuse), with market value credited to the club.
          Hit the manager target but miss <b>club</b> expectation both seasons and the club sacks them (MV credited).`,
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
      html: `This is separate from <b>manager retention</b> over a 2-season deal — you can face listing, board fine, and manager exit in the same window.
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
