/** Squad, contracts, managers */

export const SECTION_SQUAD = {
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
        `<b>One of our own</b> or <b>Fan Favourite</b> — choose one (not both). OooO = home-grown star (excused from star cap/tax), only if your nation has GPDB 79+ players. Fan Favourite = any 76–78 (any nation); Central Bank pays <b>50%</b> of their wage. Editable in <b>GPSL preseason</b> or <b>January</b> only. Nations with no GPDB stars get Fan Favourite only.`,
        {
          html: `<b>August enforcement</b> — from GPSL August, clubs still short on size / HG / U21, or over the star cap, are auto-fixed once:`,
          children: [
            `<b>₿2.5m fine</b> per missing player (or per star released) + <b>₿2.5m</b> season-loan fee when a loan is issued.`,
            `Emergency loans are rating <b>≤72</b>, prefer home-grown, else any nation; picks favour positional gaps (2 GK / 8 DEF / 8 MID / 6 ATT) for the loan only.`,
            `At 28 players, lowest eligible players are released (100% MV) to make room — never HG when fixing HG, never U21 when fixing U21, and <b>never OooO</b>.`,
            `Over the star cap: lowest-rated stars released at <b>market value</b> + ₿2.5m fine each (OooO protected); if that would drop under 24, a loan is taken first.`,
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
      items: [
        { href: "legacy_players.html", label: "Legacy players (league list)" },
        { href: "squad.html", label: "Squad" },
        { href: "expiring_contracts.html", label: "Expiring Contracts" },
        { href: "GPDB.html", label: "Player Database" },
        { href: "player_career.html", label: "Player career" },
      ],
    },
  ],
};

export const SECTION_MANAGERS = {
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
        `Use <b>View</b> to check live bids and history without bidding. Do <b>not</b> open auctions just to force rivals’ max/auto-bids upward — probing to inflate prices is against fair play.`,
        `When the random finish passes, winning bids are settled automatically (manager assigned, fee debited). If a club already has a manager, that auction closes without a transfer.`,
        `Season expectations message arrives in your <a href="inbox.html">Inbox</a> when a manager is signed.`,
      ],
    },
  ],
};
