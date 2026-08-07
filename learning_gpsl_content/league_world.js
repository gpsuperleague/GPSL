/** League, cups, international */

export const SECTION_LEAGUE = {
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
};

export const SECTION_INTERNATIONAL = {
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
};
