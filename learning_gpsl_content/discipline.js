/** Deadlines, fines, points deductions, repeat offences — owner handbook */

export const SECTION_DISCIPLINE = {
  id: "discipline",
  title: "Discipline &amp; fines",
  blocks: [
    {
      type: "p",
      html: `One place for <b>deadlines</b>, <b>automatic fines</b>, <b>matchday / recording penalties</b>,
        <b>points deductions</b>, and what happens on <b>repeat offences</b>. Applied charges always
        appear in your <a href="inbox.html">Inbox</a> and on your club balance / ledger.`,
    },
    {
      type: "links",
      items: [
        { href: "inbox.html", label: "Inbox" },
        { href: "matchday.html", label: "Match Day (console rules)" },
        { href: "#match-scheduling", label: "Match scheduling (full walkthrough)" },
        { href: "#matchday-checklist", label: "Matchday checklist / recording" },
        {
          href: "docs/gpsl-month-end-unplayed.html",
          label: "Month end & unplayed (detail)",
        },
      ],
    },

    { type: "h3", html: "Deadlines (keep these)" },
    {
      type: "ul",
      items: [
        `<b>GPSL month</b> — Thursday <b>19:00 UK</b> → next Thursday 19:00 UK. Month lock is when many automatic fines and window checks run.`,
        `<b>Home propose</b> — arrange a kick-off <b>before the prior month locks</b> (e.g. September game → propose before August ends). Last <b>48 hours</b> before the play month opens = late band.`,
        `<b>Reply / counter</b> — each negotiation turn has a deadline (often <b>24 hours</b>; shown on Schedule and Inbox).`,
        `<b>Check-in</b> — from <b>10 minutes before</b> agreed kick-off until <b>10 minutes after</b>.`,
        `<b>Match video</b> — post your YouTube link after the match; missing-video money fine + points ladder start after <b>month lock + grace</b> (default <b>72 hours</b>).`,
        `<b>New owners</b> — appointed mid-month get a scheduling-fine pass until their first full GPSL month (see Inbox / Owner board if unsure).`,
      ],
    },
    {
      type: "tip",
      html: `Deadline warnings land in Inbox before cut-offs. Act early — most scheduling fines only hit at <b>month lock</b>, not the second your reply clock hits zero.`,
    },

    { type: "h3", html: "Automatic scheduling fines (league &amp; cups)" },
    {
      type: "p",
      html: `These are charged by the site at GPSL month lock when the match system is ON for the fixture. Full pathways:
        <a href="#match-scheduling">Match scheduling</a>.`,
    },
    {
      type: "ul",
      items: [
        `<b>₿2.5m</b> — home never proposed by the prior-month lock (can <b>repeat each later lock</b> until they propose). Suppressed while home is on a booked holiday.`,
        `<b>₿1m</b> — home’s first proposal only in the last 48h before the play month opened.`,
        `<b>Warning → ₿2.5m</b> — reply overdue at lock: first lock is Inbox warning only; still overdue at a later lock → fine. Negotiation continues.`,
        `<b>₿2.5m + 3–0</b> — one-sided no-show recorded, match still unfinished at month lock.`,
        `<b>₿3m + 3–0</b> — emergency drop (&lt;24h before KO) with no season allowance left (2 per season).`,
        `<b>₿2.5m each + mutual forfeit</b> — both clubs had GPSL match system OFF and the fixture is still unplayed at that month’s lock (0 points each; cups both out).`,
      ],
    },

    { type: "h3", html: "Match videos — fine + points ladder (repeat offences)" },
    {
      type: "p",
      html: `After you play, each club posts its own video in Discord (format under
        <a href="#match-scheduling">Match scheduling → Match videos</a>). Missing upload is the
        clearest <b>automatic points</b> ladder in GPSL:`,
    },
    {
      type: "ul",
      items: [
        `<b>Grace</b> — after month lock + grace hours (default 72h), if your side still has no matched video: <b>₿500k</b> fine <b>and</b> <b>1 league point suspended</b> for 24 hours.`,
        `<b>Clear the suspend</b> — upload within that 24h window and the point is cancelled.`,
        `<b>Full strike</b> — still missing after 24h → <b>−1 point</b> on the table (counts as a full strike for the season).`,
        `<b>3rd full strike in a season</b> — extra <b>−9 points now</b>, plus <b>−3 points carried into next season</b>.`,
      ],
    },
    {
      type: "warn",
      html: `Video money fines and the points ladder are separate from peer <b>R</b> reports (recording / pitch breaches). Upload on time even if you already paid a scheduling fine.`,
    },

    { type: "h3", html: "Recording &amp; matchday breaches (peer report → fine)" },
    {
      type: "p",
      html: `Console checklist is on <a href="matchday.html">Match Day</a> and
        <a href="#matchday">Match day &amp; results</a>. Opponents report breaches with the Fixtures
        <b>R</b> button. If upheld, admin applies the matching tariff (typical amounts below).`,
    },
    {
      type: "ul",
      items: [
        `<b>₿20m</b> — DOGSO.`,
        `<b>₿10m</b> — individual player instructions used; Show Manager / Subtactic / Squad / PA not displayed as required; illegal PA / SA; Red/Blue before allowed minute; Double Red/Blue misuse; match manipulation / timewasting / showboating / own-goal offences; illegal match termination; form manipulation; many “incorrect conditions” display failures.`,
        `<b>₿7.5m</b> — deliberate foul play.`,
        `<b>₿5m</b> — some PA/SA “sub” offences; ineligible starter (short stint); U21 / HG matchday failure; no GK; non-display scoreboard.`,
        `<b>₿2.5m</b> — incorrect matchroom / ready-up / stadium / season / club / kit selection; ineligible unused sub.`,
        `<b>₿1m</b> — incorrect club name &amp; abbreviation; incorrect custom stadium settings; incorrect results format.`,
      ],
    },
    {
      type: "tip",
      html: `Amounts follow the league fine catalogue (Admin → Apply fines). Exact label on your Inbox / ledger wins if a tariff was updated.`,
    },

    { type: "h3", html: "Other common club fines" },
    {
      type: "ul",
      items: [
        `<b>Squad overflow</b> — forced release can carry a <b>₿10m</b> fine when no foreign-sale slot is available (<a href="#squad">Squad</a>).`,
        `<b>Under 24 / over star cap</b> — auto path can fine <b>₿2.5m</b> per missing player or released star, plus loan fees.`,
        `<b>Withdraw from sale / withdraw bid</b> — <b>₿30m</b> / <b>₿15m</b> catalogue tariffs.`,
        `<b>FFP</b> — balance at or below <b>−₿100m</b> at Close Finances triggers FFP penalties (fine, forced MV sales, buy ban) — see <a href="#finances">Finances</a>.`,
        `<b>Board expectation miss</b> — club target miss can take <b>10%</b> of your personal Building Society balance (<a href="#club-expectations">Club expectations</a>).`,
      ],
    },

    { type: "h3", html: "League points deductions" },
    {
      type: "ul",
      items: [
        `<b>Automatic (videos)</b> — suspended −1 → full −1 → 3rd-strike −9 (+ next-season −3), as above.`,
        `<b>Automatic (results)</b> — forfeits and awards change the table (e.g. 3–0 no-show, mutual forfeit 0 pts, window awards). Those are result outcomes, not a separate “discipline points” button.`,
        `<b>Manual</b> — league admin can apply a table adjustment (positive or negative) with a written reason. You get an Inbox <b>points deduction</b> message linking to the table.`,
      ],
    },
    {
      type: "p",
      html: `There is <b>no fixed public ladder</b> that maps every matchday fine to an automatic points hit.
        Serious or repeated conduct issues (beyond the video 3-strike rule) are handled by admin using fines,
        points adjustments, and — where needed — further sporting sanctions.`,
    },

    { type: "h3", html: "Repeat offences &amp; further punishment" },
    {
      type: "ul",
      items: [
        `<b>Scheduling — no proposal</b> — the ₿2.5m Match Management fine can land again at <b>every later month lock</b> until home proposes.`,
        `<b>Scheduling — overdue reply</b> — warn once, then fine at later locks while still overdue.`,
        `<b>Missing videos</b> — each full −1 is a strike; <b>third</b> in a season triggers the −9 / −3 carry escalation (once per club per season for that escalate).`,
        `<b>Recording / pitch / eligibility</b> — each upheld report is fined from the tariff. Repeat or aggravated cases can add <b>further fines</b>, <b>manual points deductions</b>, forced rearrangements, or other sanctions decided by league admin.`,
        `<b>Disputes</b> — raise calmly on Discord with evidence (video timestamps help). Site errors may be compensated (League Compensation tariff).`,
      ],
    },
    {
      type: "warn",
      html: `GPSL expects fair play: no DOGSO, no timewasting, no match manipulation, correct console displays on the recording. If you are unsure before kick-off, pause and fix settings — cheaper than a ₿10m report.`,
    },
  ],
};
