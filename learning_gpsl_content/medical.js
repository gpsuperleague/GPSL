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
