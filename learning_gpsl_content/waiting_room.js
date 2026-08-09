/** Waiting list / pre-club / club draft auction */

export const SECTION_WAITING_ROOM = {
  id: "waiting-room",
  title: "The Waiting Room &amp; club auction",
  blocks: [
    {
      type: "p",
      html: `Until you own a club, the site opens <b>The Waiting Room</b> — a short menu only:
        waiting list, owner details, club / player / manager databases, and the club draft auction.
        Admin invites you from the waiting list when a club slot is ready; then you bid from your starting bank balance.`,
    },
    {
      type: "links",
      items: [
        { href: "waiting_list.html", label: "Owner waiting list" },
        { href: "awaiting_club.html", label: "Owner details" },
        { href: "club_auction.html", label: "Club draft auction" },
        { href: "club_database.html", label: "Club Database" },
        { href: "GPDB.html", label: "Player Database" },
        { href: "MGDB.html", label: "Manager Database" },
      ],
    },
    { type: "h3", html: "Before you can bid" },
    {
      type: "ul",
      items: [
        `<b>Owner tag</b> — set on <a href="awaiting_club.html">Owner details</a>. Shown on the waiting list and as the auction leader.
          Once you are invited to the club auction, the tag <b>locks</b> and cannot be changed without admin help.`,
        `<b>Timezone</b> and <b>match availability</b> — also on Owner details. Required before you can enter the auction room and place bids
          (used later for fixture scheduling).`,
        `<b>Starting bank balance</b> — league-set budget for new owners (currently <b>₿650m</b>). Shown in the nav and on Owner details.
          Your winning bid is deducted when the club is assigned; the remainder becomes your club balance.`,
      ],
    },
    { type: "h3", html: "Club draft auction rules" },
    {
      type: "ul",
      items: [
        `You must be <b>invited</b> by admin (Auction tick on the admin waiting list) — status <code>awaiting_club_auction</code>.`,
        `<b>Opening bids</b> reflect club prestige and stadium (stadium cost = capacity × ₿1,500, same as Club Database stadium value). Check capacity, expected finish, gate income, and maintenance on the auction page before you bid.`,
        `<b>Countdown</b> — same timed window style as other drafts (Day 1 19:00 UK start when enabled). The timer only appears when the <b>club</b> auction is on — not when player/manager drafts are on.`,
        `You may only <b>lead one club</b> at a time. When the window closes, the highest bidder wins; settlement assigns the club and opens the full site.`,
      ],
    },
    {
      type: "tip",
      html: `You can fill in Owner details while still on the waiting list. Bidding unlocks only after admin invites you.
        Once you have a club, your badge appears in the nav and the full owner menus unlock.`,
    },
  ],
};
