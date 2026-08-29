/** Match scheduling & match day */

export const SECTION_MATCH_SCHEDULING = {
  id: "match-scheduling",
  title: "Match scheduling",
  blocks: [
    {
      type: "p",
      html: `League fixtures are published when the season starts. You and your opponent must <b>agree a kick-off</b>
        before playing. Set weekly availability on <a href="owner_details.html">Owner Details</a> (or during
        The Waiting Room on <a href="awaiting_club.html">Owner details</a>), then use
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
        `<b>Play</b> — league and cup matches should be played in their fixture GPSL month. If a month ends still unplayed, the fixture becomes <b>catch-up</b> (highlighted on Fixtures) and can be played in a later month. Month-end arrangement / reply / no-show fines apply to <b>league and all cups</b>.`,
      ],
    },
    { type: "h3", html: "1 — Availability" },
    {
      type: "ul",
      items: [
        `<b>Owner Details → weekly availability</b> — 30-minute blocks (UK time) Mon–Sun when you are usually free.`,
        `Set your <b>timezone</b> so kick-off times show in your local clock on the schedule page.`,
        `<b>Holidays</b> (up to 14 days/season) block availability and unlock early arrange/play for overlapping GPSL months (e.g. book Aug–Sep holiday in June → play those fixtures in June/July). Both clubs need a full squad (min 24). Book only <b>before</b> that GPSL month opens. Cancel/amend while still upcoming; after it starts, admin manages via Season Management → Owner holidays.`,
      ],
    },
    { type: "h3", html: "2 — Agree a time" },
    {
      type: "ul",
      items: [
        `<b>Home club proposes first</b> — pick a slot from <b>your</b> weekly availability (opponent does not need theirs set yet).`,
        `Away owner gets an <a href="inbox.html">Inbox</a> message — <b>Accept</b> or counter-propose from their own availability when ready.`,
        `<b>No double-booking</b> — a 30-minute kick-off already agreed (or pending) for either club is blocked for other fixtures.`,
        `After two proposals each, the site suggests agreeing on <b>Discord</b>, then picking a slot on the schedule page.`,
        `<b>Response deadlines</b> apply while negotiating — the site tracks overdue turns during the month. <b>Missed response fines (default ₿2.5m)</b> are assessed when that fixture’s <b>play GPSL month locks</b>, not instantly mid-week.`,
        `<b>Weekly availability</b> is tied to your owner account and survives vanilla reset / new seasons — set it once on Owner Details (or in the waiting room).`,
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
    { type: "h3", html: "Scheduling fines (league &amp; cups — assessed at month lock)" },
    {
      type: "ul",
      items: [
        `<b>Match Management (₿10m)</b> — home never proposed by the arrangement deadline; can repeat each month until a proposal is made.`,
        `<b>Late arrangement (₿5m)</b> — first home proposal in the last 24h before the play month opens (either/or with Match Management at that lock).`,
        `<b>Missed response (₿2.5m)</b> — still negotiating with an overdue response when the play month locks.`,
        `<b>No-show at agreed kick-off (₿5m + 3–0)</b> — one club checked in, the other did not, and the match never received a normal result before month lock.`,
        `These fines and catch-up apply to <b>league and all cup</b> fixtures the same way.`,
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
};
