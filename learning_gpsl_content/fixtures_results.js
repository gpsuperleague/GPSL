/** Match scheduling & match day — owner-friendly handbook */

export const SECTION_MATCH_SCHEDULING = {
  id: "match-scheduling",
  title: "Match scheduling",
  blocks: [
    {
      type: "p",
      html: `Before you can play a <b>league or cup</b> game, you and your opponent must
        <b>agree a kick-off on the site</b> (Discord chat is fine for talking — the time still needs
        to be set here). Same rules for all cups.`,
    },
    {
      type: "links",
      items: [
        { href: "owner_details.html", label: "Owner Details (availability)" },
        { href: "fixtures.html", label: "Fixtures" },
        { href: "club_fixtures.html", label: "My club fixtures" },
        { href: "inbox.html", label: "Inbox" },
        {
          href: "docs/gpsl-month-end-unplayed.html",
          label: "Month end & unplayed (full guide)",
        },
      ],
    },

    { type: "h3", html: "The short version" },
    {
      type: "ul",
      items: [
        `<b>1.</b> Set your weekly availability on <a href="owner_details.html">Owner Details</a>.`,
        `<b>2.</b> <b>Home proposes first</b> on Fixtures → Schedule (or via Inbox). Away accepts or counters.`,
        `<b>3.</b> At kick-off, both <b>check in within 10 minutes</b>, then enter the result on Match Day.`,
        `<b>4.</b> If the month ends and the game still isn’t played, it becomes <b>catch-up</b> — you can still play it later. It is <b>not</b> an automatic 3–0 (unless there was a recorded no-show).`,
      ],
    },

    { type: "h3", html: "GPSL months" },
    {
      type: "ul",
      items: [
        `One real week = one <b>GPSL month</b>: <b>Friday 19:00 UK → next Friday 19:00 UK</b> (August–May, then Playoffs). The nav badge shows the live month.`,
        `<b>Arrange early.</b> Example: a <b>September</b> fixture should be arranged before <b>August</b> ends.`,
        `<b>Play in that month</b> when you can. If you don’t finish in time, the fixture rolls into <b>catch-up</b> (highlighted on Fixtures).`,
      ],
    },

    { type: "h3", html: "1 — Availability" },
    {
      type: "ul",
      items: [
        `On <a href="owner_details.html">Owner Details</a>, mark the <b>30-minute blocks</b> (UK time) you are free each week.`,
        `Set your <b>timezone</b> so kick-offs show in your local time.`,
        `Availability stays with your owner account across seasons — set it once.`,
        `<b>Holidays</b> (up to 14 days/season) can unlock early arrange/play for overlapping months. Book before that GPSL month opens; both clubs need a full squad (min 24). Details on Owner Details.`,
      ],
    },

    { type: "h3", html: "2 — Agree a time" },
    {
      type: "ul",
      items: [
        `<b>Home proposes first</b> — pick a slot from <em>your</em> availability (opponent does not need theirs set yet).`,
        `Away gets an <a href="inbox.html">Inbox</a> message — <b>Accept</b> or <b>counter</b> with their own slot.`,
        `You can’t double-book a 30-minute slot already agreed or pending for either club.`,
        `After a couple of proposals each way, the site may suggest finishing the chat on <b>Discord</b>, then locking the slot on the schedule page.`,
        `<b>Reply on time.</b> While you are negotiating, each turn has a deadline (often 24 hours — see the schedule page / Inbox). Money is not taken the moment you go overdue; it is assessed when the <b>GPSL month locks</b>.`,
      ],
    },

    { type: "h3", html: "3 — Check in &amp; play" },
    {
      type: "ul",
      items: [
        `At the agreed kick-off, both owners open the <b>schedule page</b> and <b>Check in within 10 minutes</b>.`,
        `When both have checked in, Match Day unlocks for a <b>30-minute</b> play window.`,
        `<b>Both miss check-in</b> — no fine. Pick a new time on the schedule page and try again.`,
        `<b>Only one checks in</b> — recorded as a no-show, but <b>not</b> an instant 3–0. If you still play and confirm a normal result, you are fine. If the next month lock arrives and the match is still unfinished, the no-show club gets <b>3–0 + ₿5m</b> (same rule for catch-up games arranged later).`,
        `<b>Voluntary drop</b> (≥24h before KO) — 1 per GPSL month; back to arranging. Not on catch-up.`,
        `<b>Emergency drop</b> (&lt;24h before KO) — 2 per season; if none left → 3–0 + fine. Not on catch-up.`,
        `<b>Mutual override</b> — either club can ask to play now or pick a new time; both must confirm in Inbox (expires in 24 hours).`,
      ],
    },

    { type: "h3", html: "4 — What happens at month end?" },
    {
      type: "p",
      html: `When a GPSL month closes (Friday 19:00 UK), the league checks unfinished <b>league and cup</b> fixtures. Remember: an unfinished arrangement does <b>not</b> mean the match is lost 3–0.`,
    },
    {
      type: "ul",
      items: [
        `<b>Still unplayed, no no-show</b> → becomes <b>catch-up</b>. Keep arranging and playing in later months.`,
        `<b>Someone didn’t reply</b> while you were proposing/countering → that club is fined <b>₿2.5m</b>. The fixture <b>rolls over</b>; the propose/counter process <b>restarts</b> (home proposes again next month). This can happen again each month if replies keep stalling.`,
        `<b>Recorded one-sided no-show</b> and still unfinished → <b>3–0 + ₿5m</b> for the no-show club. Fixture is finished.`,
        `<b>Home never proposed</b> by the arrangement deadline → <b>₿10m</b> Match Management (can repeat later months until they propose). First proposal only in the last 24h before the play month opens → <b>₿5m</b> late fee instead (not both at that check).`,
        `You can still arrange on Discord — just get a result on the site (or a proper scheduled kick-off) before lock if you want to avoid reply / no-show issues.`,
      ],
    },

    { type: "h3", html: "5 — Catch-up games" },
    {
      type: "ul",
      items: [
        `Shown with a <b>catch-up</b> badge on <a href="fixtures.html">Fixtures</a> / <a href="club_fixtures.html">My club fixtures</a>.`,
        `Propose times in the <b>current</b> GPSL month. Reply deadlines still apply; missed replies can fine at the next month lock, then arrangement restarts again.`,
        `If you agree a kick-off and one side no-shows, the same <b>3–0 + ₿5m</b> rule applies at the next month lock if you never finish the match.`,
        `Voluntary / emergency drops are <b>not</b> available on catch-up — use the schedule page reset for a stale agreed time if needed.`,
      ],
    },

    { type: "h3", html: "Fines at a glance (league &amp; all cups)" },
    {
      type: "ul",
      items: [
        `<b>₿10m</b> — home never proposed (can repeat each month until they do).`,
        `<b>₿5m</b> — home first proposed in the last 24h before the play month opened.`,
        `<b>₿2.5m</b> — you owed a reply and were overdue when the month locked (fixture rolls over; arrange again).`,
        `<b>₿5m + 3–0</b> — one-sided no-show, match never finished before month lock.`,
        `<b>₿3m + 3–0</b> — emergency drop with no season allowance left.`,
      ],
    },
    {
      type: "tip",
      html: `Fines appear in <a href="inbox.html">Inbox</a> and on your balance. Longer walkthrough:
        <a href="docs/gpsl-month-end-unplayed.html">Month end &amp; unplayed fixtures</a>.
        Site error? Ask league admin on Discord about compensation.`,
    },

    { type: "h3", html: "Inbox — what you’ll see" },
    {
      type: "ul",
      items: [
        `<b>Match time proposed / countered</b> — Accept or open Schedule to counter.`,
        `<b>Match time agreed</b> — check in at kick-off.`,
        `<b>Reschedule / catch-up reset</b> — scheduling reopened; home proposes again.`,
        `<b>Fine applied</b> — scheduling or matchday; the note explains which fixture.`,
      ],
    },
  ],
};

export const SECTION_MATCHDAY = {
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
        `You need an <b>agreed kick-off</b> and <b>both check-ins</b> before you can enter a result (see <a href="#match-scheduling">Match scheduling</a>).`,
        `If you missed check-in, use <b>Pick new time</b> on the schedule page first.`,
        `<b>Catch-up</b> games can be played in a later GPSL month once re-scheduled.`,
        `Submit score and squad stats on <a href="matchday.html">Match Day</a>. Opponent confirms or rejects via Inbox.`,
        `<b>League:</b> win 3 pts, draw 1, loss 0. <b>Cups:</b> no draws — extra time / pens if needed.`,
        `Confirmed results update tables, stats, and finances where applicable.`,
        `Holiday early-play: result can be saved early; league table/stats wait until that GPSL month is active. See <a href="owner_details.html">Owner Details</a>.`,
      ],
    },
  ],
};
