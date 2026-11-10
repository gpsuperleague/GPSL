/** Medical Room — doctor, physios, specialist consultants */

export const SECTION_MEDICAL = {
  id: "medical-room",
  title: "Medical Room",
  blocks: [
    {
      type: "p",
      html: `Open <a href="medical_room.html">Medical Room</a> from My Club. Hire a <b>club doctor</b> and
        <b>physios</b>, then use <b>specialist consultant</b> tokens to shorten injuries.
        Staff hiring is only open in <b>GPSL June–August</b> (closed September–May).`,
    },
    { type: "h3", html: "How an injury happens" },
    {
      type: "ul",
      items: [
        `After a <b>played</b> league or cup match, from <b>August</b> onward, each club is rolled <b>once</b> if someone from that club actually played. <b>June and July do not roll.</b>`,
        `A club stops at <b>4 injuries</b> in a season: at most <b>1 major</b>, <b>2 moderate</b>, and <b>4 minor</b>, and never more than 4 in total.`,
        `After an injury, <b>5</b> of that club’s matches must pass before it can be hit again.`,
        `The chance is paced across the matches still left, held between <b>3% and 12%</b>, so a club is steered toward those 4 rather than hit at random all year. Physios then take their percentages off. Each club also has a small season-long swing, so two similar clubs are not identical.`,
        `Players who appeared while at <b>Fitness Concern</b> or <b>Injury Risk</b> push that match’s chance up. The extra is capped.`,
        `The player is picked from those who played. Your last fit goalkeeper is left out of the draw.`,
        `<b>Injured</b> — still has matches to miss, and cannot be selected for those. <b>Regaining fitness</b> — the missed matches are done; he can play while the meter climbs back. Length comes from the injury itself.`,
      ],
    },
    { type: "h3", html: "Match fitness" },
    {
      type: "ul",
      items: [
        `Every player has a meter: <b>Fully Fit → Match Ready → Managing Load → Fitness Concern → Injury Risk</b>.`,
        `Consecutive league or cup appearances climb it (about <b>4</b> in a row per step). Missing a club match drops one step.`,
        `Higher steps are more likely to be the one injured, and tilt toward a worse injury. They do not change how long that injury type lasts.`,
        `While he is hurt the squad label reads Injured or Regaining fitness. The meter keeps tracking underneath.`,
      ],
    },
    { type: "h3", html: "Club doctor" },
    {
      type: "ul",
      items: [
        `<b>Required</b> before specialist consults will work.`,
        `Assesses each injury. While hired, every <b>new</b> injury is shortened by <b>1 match</b> (out phase).`,
        `Name and gender assigned at random on hire. <b>3-season</b> contract, then retires.`,
        `Hire only in <b>June–August</b>.`,
      ],
    },
    { type: "h3", html: "Physiotherapists" },
    {
      type: "p",
      html: `Fixed ladder — hire grades <b>1 → 5</b> in order (each unlocks the next). Each grade cuts squad
        injury chance a little more. Name and gender assigned at random. <b>3-season</b> contracts.
        Hire only in <b>June–August</b>.`,
    },
    {
      type: "ul",
      items: [
        `<b>1</b> Trainee −0.2% (₿500k)`,
        `<b>2</b> Physio −0.35% (₿750k)`,
        `<b>3</b> Senior −0.6% (₿1.25m)`,
        `<b>4</b> Advanced −1% (₿2m)`,
        `<b>5</b> Consultant −2% (₿4m)`,
        `Full set: <b>−4.15%</b> injury chance for <b>₿8.5m</b> total.`,
      ],
    },
    { type: "h3", html: "Specialist consultants" },
    {
      type: "ul",
      items: [
        `After the doctor assesses an injury, spend <b>one consult token</b> to shorten recovery:
          <b>−2 / −4 / −6 / −8 / −10</b> matches depending on the token.`,
        `<b>Cap:</b> a consult can remove at most <b>half</b> of the matches still left on that injury
          (e.g. 18 left + a −10 token → removes 9 → <b>9 left</b>).`,
        `<b>One consult per injury</b> — you cannot stack multiple tokens on the same injury.`,
        `Same tokens work from Medical Room, <a href="club_prizes.html">Rewards Centre</a>, and the squad Action menu.`,
        `Challenge big-prize packs and other prizes can award medical tokens (e.g. 2–10 match reductions).`,
      ],
    },
    {
      type: "tip",
      html: `Injuries and suspensions also block Match Day selection — fix the squad before check-in.
        See <a href="injuries.html">Injuries</a> for league-wide status.`,
    },
    {
      type: "links",
      items: [
        { href: "medical_room.html", label: "Medical Room" },
        { href: "club_prizes.html", label: "Rewards Centre (tokens)" },
        { href: "injuries.html", label: "Injuries" },
        { href: "squad.html", label: "Squad" },
      ],
    },
  ],
};
