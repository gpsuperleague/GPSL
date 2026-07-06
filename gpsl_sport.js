/**
 * GPSL Sport — immersive newspaper modal
 */

import { stadiumImageUrl } from "./stadium_images.js";
import {
  pesdbPlayerCardUrl,
} from "./player_links.js";

let sportEditionId = null;
let sportActivePage = "front";
let sportSupabase = null;
let sportArchive = [];
let sportRefreshError = null;

const TROPHY_IMAGES = {
  superleague: "images/trophies/superleague.png",
  super8: "images/trophies/super8.png",
  plate: "images/trophies/plate.png",
  shield: "images/trophies/shield.png",
  bowl: "images/trophies/bowl.png",
  league_cup: "images/trophies/league_cup.png",
};

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(s) {
  return escapeHtml(s).replace(/'/g, "&#39;");
}

function clubBadgeUrl(short) {
  const code = String(short ?? "").trim();
  return code ? `images/club_badges/${code}.png` : null;
}

function imgTag(src, className, alt = "") {
  if (!src) return "";
  return (
    `<img class="${className}" src="${escapeAttr(src)}" alt="${escapeAttr(alt)}" loading="lazy" ` +
    `onerror="this.classList.add('is-broken')">`
  );
}

function formatParagraphs(text, dropcap = false) {
  return escapeHtml(text || "")
    .split(/\n\n+/)
    .map((p, i) => {
      const dc = dropcap && i === 0 ? " gpsl-sport-dropcap" : "";
      return `<p class="gpsl-sport-body${dc}">${p.replace(/\n/g, "<br>")}</p>`;
    })
    .join("");
}

function trophyUrl(code) {
  if (!code) return null;
  const key = String(code).toLowerCase();
  return TROPHY_IMAGES[key] || `images/trophies/${key}.png`;
}

function resolveHero(front, back, edition) {
  if (front?.hero && typeof front.hero === "object") return front.hero;

  const storyType = front?.story_type || edition?.story_type || "";

  if (storyType.includes("owner") && front?.hero?.kind === "owner_takeover") {
    return front.hero;
  }

  if (storyType.includes("preseason") || storyType.includes("transfer")) {
    const lead = back?.lead || {};
    if (lead.player_id) {
      return {
        kind: "transfer",
        club_short: lead.buyer_club_short,
        player_id: String(lead.player_id),
        caption: lead.headline || "Transfer special",
      };
    }
  }

  if (storyType === "season_review" && edition?.detail?.champion_club_short) {
    return {
      kind: "champion",
      club_short: edition.detail.champion_club_short,
      trophy: "superleague",
      caption: "Champions of the GPSL",
    };
  }

  return { kind: "generic", caption: front?.edition_label || "GPSL Sport" };
}

function renderHeroBlock(hero) {
  if (!hero) return "";

  const kind = hero.kind || "generic";
  const caption = escapeHtml(hero.caption || "");
  const clubShort = hero.club_short || hero.club_short_name;
  const stadium = stadiumImageUrl(clubShort);
  const badge = clubBadgeUrl(clubShort);

  if (kind === "manager_signing" && clubShort) {
    return `
      <figure class="gpsl-sport-hero gpsl-sport-hero-manager">
        <div class="gpsl-sport-hero-bg" style="${stadium ? `--hero-bg:url('${escapeAttr(stadium)}')` : ""}"></div>
        <div class="gpsl-sport-hero-layer gpsl-sport-hero-layer-manager">
          ${badge ? imgTag(badge, "gpsl-sport-hero-badge gpsl-sport-hero-badge-lg", "") : ""}
          ${hero.manager_name ? `<div class="gpsl-sport-hero-manager-tag">${escapeHtml(hero.manager_name)}</div>` : ""}
        </div>
        ${caption ? `<figcaption class="gpsl-sport-hero-cap">${caption}</figcaption>` : ""}
      </figure>`;
  }

  if (kind === "owner_takeover" && clubShort) {
    return `
      <figure class="gpsl-sport-hero gpsl-sport-hero-owner">
        <div class="gpsl-sport-hero-bg" style="${stadium ? `--hero-bg:url('${escapeAttr(stadium)}')` : ""}"></div>
        <div class="gpsl-sport-hero-layer gpsl-sport-hero-layer-owner">
          ${badge ? imgTag(badge, "gpsl-sport-hero-badge gpsl-sport-hero-badge-lg", "") : ""}
          ${hero.owner_tag ? `<div class="gpsl-sport-hero-owner-tag">${escapeHtml(hero.owner_tag)}</div>` : ""}
        </div>
        ${caption ? `<figcaption class="gpsl-sport-hero-cap">${caption}</figcaption>` : ""}
      </figure>`;
  }

  if (kind === "transfer" && hero.player_id) {
    const card = pesdbPlayerCardUrl(hero.player_id);
    return `
      <figure class="gpsl-sport-hero gpsl-sport-hero-transfer">
        <div class="gpsl-sport-hero-bg" style="${stadium ? `--hero-bg:url('${escapeAttr(stadium)}')` : ""}"></div>
        <div class="gpsl-sport-hero-layer">
          ${badge ? imgTag(badge, "gpsl-sport-hero-badge", "") : ""}
          ${imgTag(card, "gpsl-sport-hero-player", "Player")}
        </div>
        ${caption ? `<figcaption class="gpsl-sport-hero-cap">${caption}</figcaption>` : ""}
      </figure>`;
  }

  if (kind === "champion" || kind === "stadium") {
    const trophy = hero.trophy ? trophyUrl(hero.trophy) : null;
    return `
      <figure class="gpsl-sport-hero gpsl-sport-hero-stadium">
        <div class="gpsl-sport-hero-bg" style="${stadium ? `--hero-bg:url('${escapeAttr(stadium)}')` : ""}"></div>
        <div class="gpsl-sport-hero-layer gpsl-sport-hero-layer-champion">
          ${trophy ? imgTag(trophy, "gpsl-sport-hero-trophy", "Trophy") : ""}
          ${badge ? imgTag(badge, "gpsl-sport-hero-badge gpsl-sport-hero-badge-lg", "") : ""}
        </div>
        ${caption ? `<figcaption class="gpsl-sport-hero-cap">${caption}</figcaption>` : ""}
      </figure>`;
  }

  if (kind === "player" && hero.player_id) {
    return `
      <figure class="gpsl-sport-hero gpsl-sport-hero-player-only">
        ${imgTag(pesdbPlayerCardUrl(hero.player_id), "gpsl-sport-hero-player gpsl-sport-hero-player-solo", "Player")}
        ${caption ? `<figcaption class="gpsl-sport-hero-cap">${caption}</figcaption>` : ""}
      </figure>`;
  }

  return `
    <figure class="gpsl-sport-hero gpsl-sport-hero-generic">
      <div class="gpsl-sport-hero-bg gpsl-sport-hero-bg-fallback"></div>
      <div class="gpsl-sport-hero-masthead-watermark">GPSL Sport</div>
      ${caption ? `<figcaption class="gpsl-sport-hero-cap">${caption}</figcaption>` : ""}
    </figure>`;
}

function renderByline(text) {
  if (!text) return "";
  return `<p class="gpsl-sport-byline">${escapeHtml(text)}</p>`;
}

function renderPullQuote(text) {
  if (!text) return "";
  const q = String(text).replace(/^["']|["']$/g, "");
  return `<blockquote class="gpsl-sport-pullquote">${escapeHtml(q)}</blockquote>`;
}

function renderStorySection(title, items, opts = {}) {
  if (!title || !items?.length) return "";
  return `
    <section class="gpsl-sport-more">
      <h2 class="gpsl-sport-section-title">${escapeHtml(title)}</h2>
      <div class="${opts.columns === 1 ? "gpsl-sport-columns-1" : "gpsl-sport-columns"}">${items
        .map((s) => renderStoryCard(s, { compact: opts.compact }))
        .join("")}</div>
    </section>`;
}

const TOTM_SLOT_ORDER = [
  "GK",
  "LB",
  "CB1",
  "CB2",
  "RB",
  "LMF",
  "CMF",
  "RMF",
  "LWF",
  "CF",
  "RWF",
];

const DIVISION_ORDER = ["superleague", "championship_a", "championship_b"];

function divisionLabel(key, fallback) {
  const map = {
    superleague: "SuperLeague",
    championship_a: "Championship A",
    championship_b: "Championship B",
    championship: "Championship",
  };
  return fallback || map[key] || String(key || "").replace(/_/g, " ");
}

function stablePickIndex(seed, count) {
  let h = 2166136261;
  const s = String(seed);
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return count > 0 ? (h >>> 0) % count : 0;
}

function parseRecentForm(form, n = 5) {
  const chars = String(form || "")
    .toUpperCase()
    .replace(/[^WDL]/g, "");
  const tail = chars.slice(-n);
  let pts = 0;
  let wins = 0;
  let losses = 0;
  for (const c of tail) {
    if (c === "W") {
      pts += 3;
      wins += 1;
    } else if (c === "D") pts += 1;
    else if (c === "L") losses += 1;
  }
  return { pts, played: tail.length, wins, losses };
}

function buildStandingsLeaderTeaser(div, divisionKey, editionSeed = "") {
  const l = div.leader || {};
  const divLabel = div.division_label || divisionLabel(divisionKey);
  const chasers = Array.isArray(div.chasers) ? div.chasers : [];
  const flying = Array.isArray(div.flying) ? div.flying : [];
  const leaderFly = flying.find((f) => f.club_short === l.club_short);
  const form = l.form || leaderFly?.form || "";
  const gap = Number(chasers[0]?.pts_behind ?? l.pts_ahead ?? 0);
  const owner = String(l.owner || "").trim();
  const club = l.club_name || l.club_short || "the leaders";
  const isSuperLeague = divisionKey === "superleague";
  const formInfo = parseRecentForm(form, 5);
  const seed = `${editionSeed}|${divisionKey}|${l.club_short}|${gap}|${l.pts ?? 0}`;
  const lines = [];

  if (gap === 0) {
    lines.push(
      owner
        ? `${owner} share top spot in ${divLabel} — dead level at the summit.`
        : `${club} are level at the top of ${divLabel} with rivals right alongside.`,
      owner
        ? `No daylight at the top of ${divLabel}; ${owner} are neck and neck with the pack.`
        : `Dead heat in ${divLabel} as ${club} cannot shake their closest rivals.`,
      owner
        ? `${owner} head ${divLabel} on points but know one slip could cost them the lead.`
        : `${club} lead ${divLabel} on the thinnest of margins — every point counts now.`,
    );
  } else if (gap === 1) {
    lines.push(
      owner
        ? `${owner} lead ${divLabel} by a solitary point — every match is a cup final.`
        : `${club} top ${divLabel} by a single point with the chasers closing in.`,
      owner
        ? `One point in it at the summit of ${divLabel}; ${owner} will feel the breath on their neck.`
        : `A one-point cushion is all ${club} have at the top of ${divLabel}.`,
      owner
        ? `${owner} sit top of ${divLabel} by the narrowest margin imaginable.`
        : `${club} cling to the ${divLabel} lead by the skin of their teeth.`,
    );
  } else if (gap <= 3) {
    lines.push(
      owner
        ? `${owner} sit top of ${divLabel} with the challengers breathing down their neck.`
        : `${club} lead ${divLabel} but the chasing pack are within striking distance.`,
      owner
        ? `${owner} hold a slender ${gap}-point advantage in ${divLabel} — no room for error.`
        : `${club} have a ${gap}-point lead in ${divLabel}; far from comfortable.`,
      owner
        ? `The chasing pack are within striking distance as ${owner} head the ${divLabel} table.`
        : `Chasers lurk just behind as ${club} top the ${divLabel} standings.`,
      owner
        ? `${owner} lead ${divLabel} but this is far from a procession — ${gap} points separate them from the hunt.`
        : `A tight ${divLabel} race: ${club} lead by ${gap} with rivals poised to pounce.`,
    );
  } else if (gap <= 6) {
    lines.push(
      owner
        ? `${owner} have a handy buffer at the top of ${divLabel}, but the chasers haven't gone away.`
        : `${club} enjoy a ${gap}-point cushion in ${divLabel}, though the pack are still in touch.`,
      owner
        ? `${owner} lead ${divLabel} with a bit of breathing space — for now.`
        : `${club} have opened a useful gap at the top of ${divLabel}.`,
      owner
        ? `A ${gap}-point cushion gives ${owner} some comfort at the ${divLabel} summit.`
        : `${club} sit ${gap} points clear at the top of ${divLabel}.`,
    );
  } else if (gap <= 11) {
    lines.push(
      owner
        ? `${owner} are starting to pull away at the top of ${divLabel}.`
        : `${club} are stretching their lead at the summit of ${divLabel}.`,
      owner
        ? `${owner} have opened up a healthy gap in ${divLabel} — the challengers are playing catch-up.`
        : `The chasing pack are losing touch as ${club} build a ${gap}-point lead in ${divLabel}.`,
      owner
        ? `${gap} points clear, ${owner} look well placed at the top of ${divLabel}.`
        : `${club} command a ${gap}-point advantage in ${divLabel}.`,
    );
  } else {
    lines.push(
      owner
        ? `${owner} are in a league of their own at the top of ${divLabel}.`
        : `${club} dominate the ${divLabel} summit with a commanding lead.`,
      owner
        ? `${owner} have built a commanding ${gap}-point lead in ${divLabel} — the rest are playing catch-up.`
        : `Runaway leaders: ${club} are ${gap} points clear in ${divLabel}.`,
      owner
        ? `${owner} command ${divLabel} with daylight between them and the chasing pack.`
        : `${club} have put real distance between themselves and the rest in ${divLabel}.`,
    );
  }

  if (formInfo.played >= 3 && formInfo.pts >= 10) {
    lines.push(
      owner
        ? `Ruthless recent form has propelled ${owner} to the ${divLabel} summit.`
        : `Scorching form has ${club} flying at the top of ${divLabel}.`,
      owner
        ? `${owner} are flying at the top of ${divLabel} — results that demand respect.`
        : `${club} arrive at the ${divLabel} summit on the back of a hot streak.`,
      owner
        ? `${owner}'s purple patch has them perched atop ${divLabel}.`
        : `A run of strong results has ${club} leading the ${divLabel} charge.`,
    );
  } else if (formInfo.played >= 3 && formInfo.pts <= 4 && gap <= 6) {
    lines.push(
      owner
        ? `${owner} still lead ${divLabel} despite a wobble in recent weeks — nervy times at the top.`
        : `${club} cling to the ${divLabel} lead despite dipping form.`,
      owner
        ? `The table says first; recent results say worry for ${owner} in ${divLabel}.`
        : `Leading ${divLabel} on points but not on form — ${club} will want a response.`,
    );
  }

  if (isSuperLeague && gap >= 4) {
    lines.push(
      owner
        ? `${owner} set the pace in the SuperLeague title race.`
        : `${club} are the team to catch at the top of the SuperLeague.`,
      owner
        ? `SuperLeague summit: ${owner} have the title race firmly in their sights.`
        : `The SuperLeague crown looks within reach for ${club} right now.`,
    );
  } else if (!isSuperLeague && gap >= 3) {
    lines.push(
      owner
        ? `${owner} head the promotion chase in ${divLabel}.`
        : `${club} lead the automatic promotion picture in ${divLabel}.`,
      owner
        ? `Promotion talk is getting louder around ${owner} at the top of ${divLabel}.`
        : `${club} are setting the promotion pace in ${divLabel}.`,
    );
  }

  if (!owner) {
    lines.push(
      `Top of ${divLabel}: ${club} on ${l.pts ?? 0} points with the chasing pack in pursuit.`,
      `${club} lead ${divLabel} after a busy month at the sharp end.`,
    );
  }

  const idx = stablePickIndex(seed, lines.length);
  return lines[idx] || `Top of ${divLabel} after a busy month.`;
}

function sortTotmRows(rows) {
  return [...(rows || [])].sort(
    (a, b) => TOTM_SLOT_ORDER.indexOf(a.pitch_slot) - TOTM_SLOT_ORDER.indexOf(b.pitch_slot)
  );
}

function renderTotmCard(player) {
  if (!player?.player_id) return "";
  const card = pesdbPlayerCardUrl(String(player.player_id));
  const badge = clubBadgeUrl(player.club_short);
  const stats = [
    player.appearances != null ? `${player.appearances} apps` : null,
    player.goals != null ? `${player.goals}G` : null,
    player.assists != null ? `${player.assists}A` : null,
    player.avg_rating != null ? Number(player.avg_rating).toFixed(2) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return `
    <div class="gpsl-sport-totm-card">
      ${imgTag(card, "gpsl-sport-totm-player", player.player_name || "")}
      <div class="gpsl-sport-totm-meta">
        <span class="gpsl-sport-totm-slot">${escapeHtml(player.slot_label || player.pitch_slot || "")}</span>
        <span class="gpsl-sport-totm-name">${escapeHtml(player.player_name || "—")}</span>
        <span class="gpsl-sport-totm-club">
          ${badge ? imgTag(badge, "gpsl-sport-totm-badge", "") : ""}
          ${escapeHtml(player.club_name || player.club_short || "")}
        </span>
        ${stats ? `<span class="gpsl-sport-totm-stats">${escapeHtml(stats)}</span>` : ""}
      </div>
    </div>`;
}

function renderTotmSection(title, rows) {
  const sorted = sortTotmRows(rows);
  if (!sorted.length) {
    return `<section class="gpsl-sport-totm-block">
      <h3 class="gpsl-sport-subsection-title">${escapeHtml(title)}</h3>
      <p class="gpsl-sport-empty-note">No Team of the Month lineup for this division yet.</p>
    </section>`;
  }

  return `
    <section class="gpsl-sport-totm-block">
      <h3 class="gpsl-sport-subsection-title">${escapeHtml(title)}</h3>
      <div class="gpsl-sport-totm-grid">${sorted.map((p) => renderTotmCard(p)).join("")}</div>
    </section>`;
}

function renderScorerRow(scorer, rank) {
  const card = scorer.player_id ? pesdbPlayerCardUrl(String(scorer.player_id)) : null;
  const badge = clubBadgeUrl(scorer.club_short);
  return `
    <li class="gpsl-sport-scorer-row">
      <span class="gpsl-sport-scorer-rank">${rank}</span>
      ${card ? `<div class="gpsl-sport-scorer-card">${imgTag(card, "gpsl-sport-scorer-player", "")}</div>` : ""}
      <div class="gpsl-sport-scorer-info">
        <span class="gpsl-sport-scorer-name">${escapeHtml(scorer.player_name || "—")}</span>
        <span class="gpsl-sport-scorer-club">
          ${badge ? imgTag(badge, "gpsl-sport-scorer-badge", "") : ""}
          ${escapeHtml(scorer.club_name || scorer.club_short || "")}
          ${scorer.owner ? ` · ${escapeHtml(scorer.owner)}` : ""}
        </span>
      </div>
      <span class="gpsl-sport-scorer-goals">${escapeHtml(String(scorer.goals ?? 0))}G</span>
    </li>`;
}

function renderTopScorersSection(topScorers) {
  const data = topScorers && typeof topScorers === "object" ? topScorers : {};
  const blocks = DIVISION_ORDER.filter((k) => Array.isArray(data[k]) && data[k].length)
    .map((key) => {
      const rows = data[key];
      return `
        <div class="gpsl-sport-scorers-division">
          <h3 class="gpsl-sport-subsection-title">${escapeHtml(divisionLabel(key))} golden boot</h3>
          <ol class="gpsl-sport-scorer-list">
            ${rows.map((s, i) => renderScorerRow(s, i + 1)).join("")}
          </ol>
        </div>`;
    })
    .join("");

  if (!blocks) return "";
  return `<section class="gpsl-sport-scorers-block">
    <h2 class="gpsl-sport-section-title">Monthly top scorers</h2>
    <div class="gpsl-sport-scorers-grid">${blocks}</div>
  </section>`;
}

function renderStandingsDivision(div) {
  if (!div) return "";
  const leader = div.leader || {};
  const chasers = Array.isArray(div.chasers) ? div.chasers : [];
  const flying = Array.isArray(div.flying) ? div.flying : [];

  const leaderBadge = clubBadgeUrl(leader.club_short);
  const chaserHtml = chasers
    .map(
      (c) => `
      <li>
        ${clubBadgeUrl(c.club_short) ? imgTag(clubBadgeUrl(c.club_short), "gpsl-sport-standings-badge", "") : ""}
        <span><strong>${escapeHtml(c.club_name || c.club_short || "")}</strong>
        ${c.owner ? ` (${escapeHtml(c.owner)})` : ""} — ${escapeHtml(String(c.pts ?? 0))} pts
        ${c.pts_behind != null && c.pts_behind > 0 ? `, ${escapeHtml(String(c.pts_behind))} behind` : ""}</span>
      </li>`
    )
    .join("");

  const flyingHtml = flying
    .map(
      (f) => `
      <li>
        ${clubBadgeUrl(f.club_short) ? imgTag(clubBadgeUrl(f.club_short), "gpsl-sport-standings-badge", "") : ""}
        <span>${escapeHtml(f.club_name || f.club_short || "")}
        ${f.owner ? ` · ${escapeHtml(f.owner)}` : ""}
        ${f.form ? ` · form ${escapeHtml(f.form)}` : ""}</span>
      </li>`
    )
    .join("");

  return `
    <article class="gpsl-sport-standings-division">
      <h3 class="gpsl-sport-subsection-title">${escapeHtml(div.division_label || "Division")}</h3>
      <div class="gpsl-sport-standings-leader">
        ${leaderBadge ? imgTag(leaderBadge, "gpsl-sport-standings-leader-badge", "") : ""}
        <div>
          <div class="gpsl-sport-standings-leader-name">${escapeHtml(leader.club_name || leader.club_short || "—")}</div>
          ${leader.owner ? `<div class="gpsl-sport-standings-owner">${escapeHtml(leader.owner)}</div>` : ""}
          <div class="gpsl-sport-standings-pts">${escapeHtml(String(leader.pts ?? 0))} pts · P${escapeHtml(String(leader.position ?? 1))}</div>
        </div>
      </div>
      ${chaserHtml ? `<div class="gpsl-sport-standings-chasers"><h4>Chasing the lead</h4><ul>${chaserHtml}</ul></div>` : ""}
      ${flyingHtml ? `<div class="gpsl-sport-standings-flying"><h4>Flying high</h4><ul>${flyingHtml}</ul></div>` : ""}
    </article>`;
}

function renderStandingsSection(standings) {
  const data = standings && typeof standings === "object" ? standings : {};
  const blocks = DIVISION_ORDER.map((k) => data[k]).filter(Boolean);
  if (!blocks.length) return "";

  return `
    <section class="gpsl-sport-standings-block">
      <h2 class="gpsl-sport-section-title">Division standings</h2>
      <div class="gpsl-sport-standings-grid">${blocks.map((d) => renderStandingsDivision(d)).join("")}</div>
    </section>`;
}

function renderStandingsSnapshotTeasers(snapshot, editionSeed = "") {
  const data = snapshot && typeof snapshot === "object" ? snapshot : {};
  const items = DIVISION_ORDER.map((key) => {
    const div = data[key];
    if (!div?.leader?.club_short) return null;
    const l = div.leader;
    return {
      kicker: div.division_label || divisionLabel(key),
      headline: `${l.club_name || l.club_short} lead on ${l.pts ?? 0} pts`,
      body: buildStandingsLeaderTeaser(div, key, editionSeed),
      club_short: l.club_short,
      story_kind: "standings_leader",
    };
  }).filter(Boolean);

  return renderStorySection("At the top of the tables", items, { compact: true, columns: 1 });
}

function renderStatsPage(editionLabel, statsPage) {
  const lead = statsPage.lead || {};
  const leadBlock = lead.headline || lead.body
    ? `<article class="gpsl-sport-lead-block gpsl-sport-lead-block-compact">
        <h1 class="gpsl-sport-headline">${escapeHtml(lead.headline || statsPage.page_title || "Stats special")}</h1>
        ${formatParagraphs(lead.body, true)}
      </article>`
    : "";

  return `
    <div class="gpsl-sport-page gpsl-sport-page-stats">
      ${renderMasthead(editionLabel, editionLabel, escapeHtml(statsPage.page_title || "Stats special"))}
      ${leadBlock}
      ${renderTotmSection("Super League Team of the Month", statsPage.totm_super)}
      ${renderTotmSection("Championship Team of the Month", statsPage.totm_championship)}
      ${renderTopScorersSection(statsPage.top_scorers)}
      ${renderStandingsSection(statsPage.standings)}
      <footer class="gpsl-sport-footer">GPSL Sport · Confirmed league stats · Player cards pesdb.net</footer>
    </div>`;
}

function renderMatchPage(editionLabel, matchPage) {
  const lead = matchPage.lead || {};
  const fixture = matchPage.fixture || {};
  const clubShort = lead.club_short || fixture.home_club;
  const hero = {
    kind: "stadium",
    club_short: clubShort,
    caption: lead.headline || matchPage.page_title || "Match of the Month",
  };

  const scoreboard = fixture.home_name
    ? `<div class="gpsl-sport-match-scoreboard">
        <div class="gpsl-sport-match-team">
          ${clubBadgeUrl(fixture.home_club) ? imgTag(clubBadgeUrl(fixture.home_club), "gpsl-sport-match-badge", "") : ""}
          <span class="gpsl-sport-match-team-name">${escapeHtml(fixture.home_name)}</span>
          ${fixture.home_owner ? `<span class="gpsl-sport-match-owner">${escapeHtml(fixture.home_owner)}</span>` : ""}
        </div>
        <div class="gpsl-sport-match-score">${escapeHtml(String(fixture.home_goals ?? 0))} – ${escapeHtml(String(fixture.away_goals ?? 0))}</div>
        <div class="gpsl-sport-match-team">
          ${clubBadgeUrl(fixture.away_club) ? imgTag(clubBadgeUrl(fixture.away_club), "gpsl-sport-match-badge", "") : ""}
          <span class="gpsl-sport-match-team-name">${escapeHtml(fixture.away_name || "")}</span>
          ${fixture.away_owner ? `<span class="gpsl-sport-match-owner">${escapeHtml(fixture.away_owner)}</span>` : ""}
        </div>
      </div>`
    : "";

  const scorers = fixture.scorers_home || fixture.scorers_away
    ? `<div class="gpsl-sport-match-scorers">
        ${fixture.scorers_home ? `<p><strong>${escapeHtml(fixture.home_name || "Home")}:</strong> ${escapeHtml(fixture.scorers_home)}</p>` : ""}
        ${fixture.scorers_away ? `<p><strong>${escapeHtml(fixture.away_name || "Away")}:</strong> ${escapeHtml(fixture.scorers_away)}</p>` : ""}
      </div>`
    : "";

  return `
    <div class="gpsl-sport-page gpsl-sport-page-match">
      ${renderMasthead(editionLabel, editionLabel, escapeHtml(matchPage.page_title || "Match of the Month"))}
      <div class="gpsl-sport-front-grid gpsl-sport-front-grid-back">
        <article class="gpsl-sport-lead-block">
          ${renderHeroBlock(hero)}
          <h1 class="gpsl-sport-headline">${escapeHtml(lead.headline || matchPage.page_title || "Match of the Month")}</h1>
          ${lead.byline ? renderByline(lead.byline) : ""}
          ${scoreboard}
          ${formatParagraphs(lead.body, true)}
          ${lead.pull_quote ? renderPullQuote(lead.pull_quote) : ""}
          ${scorers}
        </article>
      </div>
      <footer class="gpsl-sport-footer">GPSL Sport · Fictional match report · Stadium photos official GPSL assets</footer>
    </div>`;
}

function renderStoryCard(story, { compact = false } = {}) {
  const clubShort = story.club_short || story.club_short_name;
  const playerId = story.player_id ? String(story.player_id) : null;
  const isManager = story.story_kind === "manager_signing" || story.manager_id;
  const badge = clubBadgeUrl(clubShort);
  const card = playerId ? pesdbPlayerCardUrl(playerId) : null;
  const stadium = !playerId && clubShort && !isManager ? stadiumImageUrl(clubShort) : null;

  let media = "";
  if (card) {
    media = `<div class="gpsl-sport-story-media">${imgTag(card, "gpsl-sport-story-player", "")}</div>`;
  } else if (stadium && !compact) {
    media = `<div class="gpsl-sport-story-media gpsl-sport-story-media-stadium" style="--story-bg:url('${escapeAttr(stadium)}')"></div>`;
  } else if (badge) {
    media = `<div class="gpsl-sport-story-media gpsl-sport-story-media-badge">${imgTag(badge, "gpsl-sport-story-badge", "")}</div>`;
  }

  return `
    <article class="gpsl-sport-story${compact ? " gpsl-sport-story-compact" : ""}">
      <div class="gpsl-sport-story-inner">
        ${media}
        <div class="gpsl-sport-story-text">
          ${story.kicker ? `<div class="gpsl-sport-kicker">${escapeHtml(story.kicker)}</div>` : ""}
          <h3>${escapeHtml(story.headline)}</h3>
          ${story.byline ? renderByline(story.byline) : ""}
          <div class="gpsl-sport-body">${formatParagraphs(story.body)}</div>
          ${story.pull_quote ? renderPullQuote(story.pull_quote) : ""}
        </div>
      </div>
    </article>`;
}

function pickPageTopStory(page, fallbackStories, leadOnFront) {
  const stories = Array.isArray(page?.stories) ? page.stories : [];
  if (leadOnFront) {
    return stories[0] || fallbackStories?.[1] || null;
  }
  if (page?.lead?.headline) return page.lead;
  return stories[0] || fallbackStories?.[0] || null;
}

function isLegacyInseasonEdition(edition) {
  const front = edition?.front_page || {};
  const stories = Array.isArray(front.stories) ? front.stories : [];
  const legacyStory = stories.some((s) =>
    String(s.body || "").includes("Full-time in") && String(s.body || "").includes("matchday")
  );
  const rich = edition?.detail?.inseason_rich === true;
  const month = String(edition?.gpsl_month || front.gpsl_month || "").toLowerCase();
  const inseason = month && !["may", "june", "july"].includes(month);
  return inseason && !rich && (legacyStory || !edition?.stats_page?.enabled);
}

function renderLegacyUpgradeNotice(edition, refreshError) {
  if (!isLegacyInseasonEdition(edition) && !refreshError) return "";
  const msg = refreshError
    ? `Rich edition rebuild failed: ${refreshError}`
    : "This month was generated with the old GPSL Sport template. An admin must run the rich-edition SQL patch and rebuild August.";
  return `<div class="gpsl-sport-upgrade-notice" role="status">${escapeHtml(msg)}</div>`;
}

function editionSportPages(edition, front = null) {
  const fp = front || edition?.front_page || {};
  const statsPage = edition?.stats_page || edition?.detail?.stats_page || {};
  const matchPage = edition?.match_page || edition?.detail?.match_page || {};
  const statsEnabled =
    statsPage.enabled === true ||
    (edition?.detail?.inseason_rich && Object.keys(statsPage).length > 1) ||
    Boolean(fp.standings_snapshot && Object.keys(fp.standings_snapshot).length);
  const matchEnabled =
    matchPage.enabled === true ||
    Boolean(matchPage.lead?.headline || matchPage.fixture?.home_name);

  return { statsPage, matchPage, statsEnabled, matchEnabled };
}

function buildFrontRailTeasers(edition, front) {
  const teasers = [];
  const leadKind = String(front.lead_kind || front.hero?.kind || "");
  const managersPage = edition.managers_page || edition.detail?.managers_page || {};
  const ownersPage = edition.owners_page || edition.detail?.owners_page || {};
  const { statsPage, matchPage, statsEnabled, matchEnabled } = editionSportPages(edition, front);
  const back = edition.back_page || {};
  const managerStories = Array.isArray(front.manager_stories) ? front.manager_stories : [];
  const ownerStories = Array.isArray(front.owner_stories) ? front.owner_stories : [];
  const xferStories = Array.isArray(back.stories) ? back.stories : [];

  if (statsEnabled) {
    const totm = Array.isArray(statsPage.totm_super) ? statsPage.totm_super : [];
    const star = totm.find((p) => p.pitch_slot === "CF") || totm[0];
    const story = statsPage.lead?.headline
      ? {
          headline: statsPage.lead.headline,
          body: statsPage.lead.body,
          player_id: star?.player_id,
          club_short: star?.club_short,
        }
      : null;
    if (story?.headline) {
      teasers.push({ page: "stats", label: "Stats", story });
    }
  }

  if (matchEnabled && matchPage.lead?.headline) {
    teasers.push({
      page: "match",
      label: "Match report",
      story: {
        ...matchPage.lead,
        club_short: matchPage.lead.club_short || matchPage.fixture?.home_club,
      },
    });
  }

  if (managersPage.enabled) {
    const story = pickPageTopStory(
      managersPage,
      managerStories,
      leadKind.includes("manager")
    );
    if (story?.headline) {
      teasers.push({ page: "managers", label: "Managers", story });
    }
  }

  if (ownersPage.enabled) {
    const story = pickPageTopStory(
      ownersPage,
      ownerStories,
      leadKind === "owner" || leadKind === "owner_takeover"
    );
    if (story?.headline) {
      teasers.push({ page: "owners", label: "New owners", story });
    }
  }

  if (back.enabled) {
    let story = null;
    if (leadKind === "transfer") {
      story = xferStories[0] || null;
    } else {
      story = back.lead?.headline ? back.lead : xferStories[0] || null;
    }
    if (story?.headline) {
      teasers.push({ page: "back", label: "Transfers", story });
    }
  }

  return teasers;
}

function renderRailTeaser({ page, label, story }) {
  const clubShort = story.club_short || story.club_short_name;
  const playerId = story.player_id ? String(story.player_id) : null;
  const badge = clubBadgeUrl(clubShort);
  const card = playerId ? pesdbPlayerCardUrl(playerId) : null;
  const thumb = card
    ? imgTag(card, "gpsl-sport-rail-thumb-player", "")
    : badge
      ? imgTag(badge, "gpsl-sport-rail-thumb-badge", "")
      : "";
  const snippet = String(story.body || "")
    .split(/\n/)[0]
    .trim()
    .slice(0, 90);

  return `
    <a href="#" class="gpsl-sport-rail-teaser" data-sport-page="${escapeAttr(page)}" role="button">
      ${thumb ? `<div class="gpsl-sport-rail-teaser-media">${thumb}</div>` : ""}
      <div class="gpsl-sport-rail-teaser-text">
        <span class="gpsl-sport-rail-teaser-label">${escapeHtml(label)} →</span>
        <span class="gpsl-sport-rail-teaser-headline">${escapeHtml(story.headline)}</span>
        ${snippet ? `<span class="gpsl-sport-rail-teaser-snippet">${escapeHtml(snippet)}…</span>` : ""}
      </div>
    </a>`;
}

function switchSportPage(page) {
  sportActivePage = page || "front";
  document.getElementById("gpslSportTabs")?.querySelectorAll(".gpsl-sport-tab").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === sportActivePage);
  });
  renderSportPaper();
}

function renderMasthead(label, editionLabel, pageTitle) {
  const sub = pageTitle || `${escapeHtml(editionLabel)} Edition`;
  return `
    <header class="gpsl-sport-masthead">
      <div class="gpsl-sport-masthead-rule"></div>
      <div class="gpsl-sport-masthead-name">GPSL Sport</div>
      <div class="gpsl-sport-masthead-tagline">The league's paper of record</div>
      <div class="gpsl-sport-masthead-rule"></div>
      <div class="gpsl-sport-masthead-edition">${sub}</div>
    </header>
    <div class="gpsl-sport-dateline">
      <span>${escapeHtml(label || editionLabel || "GPSL")}</span>
      <span class="gpsl-sport-dateline-sep">|</span>
      <span>Free inside the GPSL</span>
    </div>`;
}

function renderInteriorPage(editionLabel, page, { defaultTitle = "GPSL Sport" } = {}) {
  const lead = page.lead || {};
  const stories = Array.isArray(page.stories) ? page.stories : [];
  const leadHero =
    lead.manager_slug || lead.story_kind === "manager_signing"
      ? {
          kind: "manager_signing",
          club_short: lead.club_short,
          manager_slug: lead.manager_slug,
          manager_name: lead.manager_name,
          caption: lead.headline || page.page_title,
        }
      : lead.story_kind === "owner_takeover"
        ? {
            kind: "owner_takeover",
            club_short: lead.club_short,
            owner_tag: lead.owner_tag,
            caption: lead.headline || page.page_title,
          }
        : lead.player_id
          ? {
              kind: "transfer",
              club_short: lead.buyer_club_short || lead.club_short,
              player_id: String(lead.player_id),
              caption: page.page_title,
            }
          : { kind: "generic", caption: page.page_title };

  const leadBlock =
    lead.headline || lead.body
      ? `<article class="gpsl-sport-lead-block">
          ${renderHeroBlock(leadHero)}
          <h1 class="gpsl-sport-headline">${escapeHtml(lead.headline || page.page_title || defaultTitle)}</h1>
          ${lead.byline ? renderByline(lead.byline) : ""}
          ${formatParagraphs(lead.body, true)}
          ${lead.pull_quote ? renderPullQuote(lead.pull_quote) : ""}
        </article>`
      : "";

  return `
    <div class="gpsl-sport-page gpsl-sport-page-interior">
      ${renderMasthead(editionLabel, editionLabel, escapeHtml(page.page_title || defaultTitle))}
      ${leadBlock ? `<div class="gpsl-sport-front-grid gpsl-sport-front-grid-back">${leadBlock}</div>` : ""}
      ${stories.length ? renderStorySection(page.page_title || defaultTitle, stories, { compact: false, columns: 1 }) : ""}
      <footer class="gpsl-sport-footer">GPSL Sport · Official GPSL assets · Player cards pesdb.net</footer>
    </div>`;
}

function renderSportPaper() {
  const paper = document.getElementById("gpslSportPaper");
  const edition = window.__gpslSportEdition;
  if (!paper || !edition) return;

  const front = edition.front_page || {};
  const back = edition.back_page || {};
  const backOwners = Array.isArray(back.owner_stories) ? back.owner_stories : [];
  const backStories = Array.isArray(back.stories) ? back.stories : [];
  const hero = resolveHero(front, back, edition);
  const editionLabel = edition.edition_label || front.edition_label || "";

  const managersPage = edition.managers_page || edition.detail?.managers_page || {};
  const ownersPage = edition.owners_page || edition.detail?.owners_page || {};
  const { statsPage, matchPage, statsEnabled, matchEnabled } = editionSportPages(edition, front);

  if (sportActivePage === "stats" && statsEnabled) {
    paper.innerHTML = renderStatsPage(editionLabel, statsPage);
    return;
  }

  if (sportActivePage === "match" && matchEnabled) {
    paper.innerHTML = renderMatchPage(editionLabel, matchPage);
    return;
  }

  if (sportActivePage === "managers" && managersPage.enabled) {
    paper.innerHTML = renderInteriorPage(editionLabel, managersPage, {
      defaultTitle: "Manager draft special",
    });
    return;
  }

  if (sportActivePage === "owners" && ownersPage.enabled) {
    paper.innerHTML = renderInteriorPage(editionLabel, ownersPage, {
      defaultTitle: "New owners",
    });
    return;
  }

  if (sportActivePage === "back" && back.enabled) {
    const lead = back.lead || {};
    const leadHero = {
      kind: "transfer",
      club_short: lead.buyer_club_short,
      player_id: lead.player_id ? String(lead.player_id) : null,
      caption: "Back page — transfer special",
    };

    paper.innerHTML = `
      <div class="gpsl-sport-page gpsl-sport-page-back">
        ${renderMasthead(editionLabel, editionLabel, escapeHtml(back.page_title || "Transfer special"))}
        <div class="gpsl-sport-front-grid gpsl-sport-front-grid-back">
          <article class="gpsl-sport-lead-block">
            ${renderHeroBlock(lead.player_id ? leadHero : hero)}
            <h1 class="gpsl-sport-headline">${escapeHtml(lead.headline)}</h1>
            ${lead.byline ? renderByline(lead.byline) : ""}
            ${formatParagraphs(lead.body, true)}
            ${lead.pull_quote ? renderPullQuote(lead.pull_quote) : ""}
          </article>
        </div>
        ${renderStorySection("New owners at the wheel", backOwners, { compact: true })}
        ${renderStorySection("Done deals", backStories, { compact: true })}
        <footer class="gpsl-sport-footer">GPSL Sport · Transfer desk · Player images via pesdb.net</footer>
      </div>`;
    return;
  }

  const railTeasers = buildFrontRailTeasers(edition, front);
  const frontStories = Array.isArray(front.stories) ? front.stories : [];
  const standingsTeasers = renderStandingsSnapshotTeasers(front.standings_snapshot, editionLabel);

  paper.innerHTML = `
    <div class="gpsl-sport-page gpsl-sport-page-front">
      ${renderLegacyUpgradeNotice(edition, sportRefreshError)}
      ${renderMasthead(editionLabel, editionLabel)}
      <div class="gpsl-sport-front-grid">
        <article class="gpsl-sport-lead-block">
          ${renderHeroBlock(hero)}
          <h1 class="gpsl-sport-headline">${escapeHtml(front.headline)}</h1>
          ${front.subhead ? `<p class="gpsl-sport-subhead">${escapeHtml(front.subhead)}</p>` : ""}
          ${front.byline ? renderByline(front.byline) : ""}
          ${formatParagraphs(front.lead_paragraph, true)}
          ${front.pull_quote ? renderPullQuote(front.pull_quote) : ""}
        </article>
        ${
          railTeasers.length
            ? `<aside class="gpsl-sport-rail">
                <h2 class="gpsl-sport-rail-title">In brief</h2>
                <div class="gpsl-sport-rail-teasers">
                  ${railTeasers.map((t) => renderRailTeaser(t)).join("")}
                </div>
              </aside>`
            : `<aside class="gpsl-sport-rail gpsl-sport-rail-empty">
                <h2 class="gpsl-sport-rail-title">Inside this edition</h2>
                <p class="gpsl-sport-rail-blurb">Use the tabs above for stats, match report, managers, owners and transfers.</p>
              </aside>`
        }
      </div>
      ${renderStorySection("Shock results", frontStories, { compact: true, columns: 1 })}
      ${standingsTeasers}
      <footer class="gpsl-sport-footer">GPSL Sport · Stadium photos &amp; club badges official GPSL assets · Player cards pesdb.net</footer>
    </div>`;
}

export function showSportModal() {
  const overlay = document.getElementById("gpslSportModal");
  if (!overlay) return;
  overlay.classList.add("is-open");
  overlay.removeAttribute("hidden");
  document.body.classList.add("gpsl-sport-open");
}

export function hideSportModal() {
  const overlay = document.getElementById("gpslSportModal");
  if (!overlay) return;
  overlay.classList.remove("is-open");
  overlay.setAttribute("hidden", "");
  document.body.classList.remove("gpsl-sport-open");
}

function renderSportArchiveSelect() {
  const wrap = document.getElementById("gpslSportArchiveWrap");
  const select = document.getElementById("gpslSportArchiveSelect");
  if (!wrap || !select) return;

  if (!sportArchive.length || sportArchive.length < 2) {
    wrap.hidden = true;
    return;
  }

  wrap.hidden = false;
  select.innerHTML = sportArchive
    .map(
      (ed) =>
        `<option value="${escapeHtml(String(ed.id))}"${
          Number(ed.id) === Number(sportEditionId) ? " selected" : ""
        }>${escapeHtml(ed.edition_label || ed.gpsl_month)}${
          ed.unread ? " (new)" : ""
        }</option>`
    )
    .join("");
}

export function ensureSportModal() {
  if (document.getElementById("gpslSportModal")) return;

  const overlay = document.createElement("div");
  overlay.id = "gpslSportModal";
  overlay.className = "gpsl-sport-modal";
  overlay.hidden = true;
  overlay.innerHTML = `
    <div class="gpsl-sport-dialog" role="dialog" aria-modal="true" aria-labelledby="gpslSportTitle">
      <button type="button" class="gpsl-sport-close" id="gpslSportClose" aria-label="Close newspaper">×</button>
      <div class="gpsl-sport-archive-wrap" id="gpslSportArchiveWrap" hidden>
        <label for="gpslSportArchiveSelect" class="gpsl-sport-archive-label">Edition archive</label>
        <select id="gpslSportArchiveSelect" class="gpsl-sport-archive-select" aria-label="Choose edition"></select>
      </div>
      <div class="gpsl-sport-tabs" id="gpslSportTabs">
        <button type="button" class="gpsl-sport-tab active" data-page="front">Front</button>
        <button type="button" class="gpsl-sport-tab" data-page="stats" id="gpslSportStatsTab" hidden>Stats</button>
        <button type="button" class="gpsl-sport-tab" data-page="match" id="gpslSportMatchTab" hidden>Match report</button>
        <button type="button" class="gpsl-sport-tab" data-page="managers" id="gpslSportManagersTab" hidden>Managers</button>
        <button type="button" class="gpsl-sport-tab" data-page="owners" id="gpslSportOwnersTab" hidden>Owners</button>
        <button type="button" class="gpsl-sport-tab" data-page="back" id="gpslSportBackTab" hidden>Transfers</button>
      </div>
      <div class="gpsl-sport-paper" id="gpslSportPaper"></div>
    </div>
  `;
  document.body.appendChild(overlay);

  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) closeGpslSport();
  });
  document.getElementById("gpslSportClose")?.addEventListener("click", closeGpslSport);
  overlay.querySelectorAll(".gpsl-sport-tab").forEach((btn) => {
    btn.addEventListener("click", () => switchSportPage(btn.dataset.page || "front"));
  });
  document.getElementById("gpslSportPaper")?.addEventListener("click", (e) => {
    const link = e.target.closest("[data-sport-page]");
    if (!link) return;
    e.preventDefault();
    switchSportPage(link.dataset.sportPage);
  });
  document.getElementById("gpslSportArchiveSelect")?.addEventListener("change", async (e) => {
    const nextId = Number(e.target.value);
    if (!nextId || nextId === Number(sportEditionId)) return;

    const paper = document.getElementById("gpslSportPaper");
    if (paper) {
      paper.innerHTML =
        '<div class="gpsl-sport-loading"><span class="gpsl-sport-loading-spinner"></span> Loading edition…</div>';
    }

    const ok = await loadSportEdition(nextId, { markRead: true, preserveViewingEdition: true });
    if (!ok) {
      renderSportArchiveSelect();
      if (paper) {
        paper.innerHTML =
          '<div class="gpsl-sport-loading">Could not load that edition. Try another month.</div>';
      }
    }
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && overlay.classList.contains("is-open")) closeGpslSport();
  });
}

async function loadSportArchive(client) {
  if (!client) return;
  try {
    const { data, error } = await client.rpc("gpsl_sport_list_editions");
    if (error) throw error;
    sportArchive = Array.isArray(data?.editions) ? data.editions : [];
  } catch (err) {
    console.warn("GPSL Sport archive:", err);
    sportArchive = [];
  }
}

function readEditionIdFromNavButton() {
  const btn = document.getElementById("gpslSportNavBtn");
  const raw = btn?.dataset?.editionId;
  if (!raw) return null;
  const id = Number(raw);
  return Number.isFinite(id) && id > 0 ? id : null;
}

export async function refreshGpslSportNav(supabase, { preserveViewingEdition = false } = {}) {
  const btn = document.getElementById("gpslSportNavBtn");
  const client = supabase || sportSupabase || window.supabase;
  if (!btn || !client) return;

  const modalOpen = document.getElementById("gpslSportModal")?.classList.contains("is-open");
  const keepViewingEdition = preserveViewingEdition || modalOpen;

  try {
    const { data, error } = await client.rpc("gpsl_sport_nav_state");
    if (error) throw error;

    if (!data?.has_edition) {
      btn.hidden = true;
      btn.removeAttribute("data-edition-id");
      btn.classList.remove("has-unread");
      if (!keepViewingEdition) sportEditionId = null;
      return;
    }

    btn.hidden = false;
    if (!keepViewingEdition) {
      sportEditionId = data.edition_id;
      btn.dataset.editionId = String(data.edition_id);
    }
    btn.title = data.headline
      ? `GPSL Sport — ${data.headline}`
      : `GPSL Sport — ${data.edition_label || "Latest"}`;
    btn.classList.toggle("has-unread", !!data.unread);

    let badge = btn.querySelector(".gpsl-sport-nav-badge");
    if (data.unread) {
      if (!badge) {
        badge = document.createElement("span");
        badge.className = "gpsl-sport-nav-badge";
        badge.textContent = "NEW";
        btn.appendChild(badge);
      }
    } else if (badge) {
      badge.remove();
    }

    await loadSportArchive(client);
  } catch (err) {
    console.warn("GPSL Sport nav:", err);
    btn.hidden = true;
    btn.removeAttribute("data-edition-id");
    sportEditionId = null;
  }
}

function syncSportTabs(edition) {
  const statsTab = document.getElementById("gpslSportStatsTab");
  const matchTab = document.getElementById("gpslSportMatchTab");
  const managersTab = document.getElementById("gpslSportManagersTab");
  const ownersTab = document.getElementById("gpslSportOwnersTab");
  const backTab = document.getElementById("gpslSportBackTab");
  const managersPage = edition?.managers_page || edition?.detail?.managers_page || {};
  const ownersPage = edition?.owners_page || edition?.detail?.owners_page || {};
  const { statsEnabled, matchEnabled } = editionSportPages(edition);
  const backEnabled = !!edition?.back_page?.enabled;

  if (statsTab) statsTab.hidden = !statsEnabled;
  if (matchTab) matchTab.hidden = !matchEnabled;
  if (managersTab) managersTab.hidden = !managersPage.enabled;
  if (ownersTab) ownersTab.hidden = !ownersPage.enabled;
  if (backTab) backTab.hidden = !backEnabled;

  const pages = ["front"];
  if (statsEnabled) pages.push("stats");
  if (matchEnabled) pages.push("match");
  if (managersPage.enabled) pages.push("managers");
  if (ownersPage.enabled) pages.push("owners");
  if (backEnabled) pages.push("back");
  if (!pages.includes(sportActivePage)) sportActivePage = "front";

  document.getElementById("gpslSportTabs")?.querySelectorAll(".gpsl-sport-tab").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === sportActivePage);
  });
}

async function loadSportEdition(editionId, { markRead = false, preserveViewingEdition = false } = {}) {
  const client = sportSupabase || window.supabase;
  if (!client || !editionId) return false;

  sportEditionId = editionId;
  const btn = document.getElementById("gpslSportNavBtn");
  if (btn && !preserveViewingEdition) btn.dataset.editionId = String(editionId);

  const { data, error } = await client.rpc("gpsl_sport_get_edition", {
    p_edition_id: editionId,
  });

  if (error || !data?.ok) {
    console.error("GPSL Sport load:", error || data);
    return false;
  }

  if (data.refresh_error) {
    console.warn("GPSL Sport refresh:", data.refresh_error);
  }

  window.__gpslSportEdition = data.edition;
  sportRefreshError = data.refresh_error || null;
  sportActivePage = "front";
  syncSportTabs(data.edition);

  renderSportArchiveSelect();
  renderSportPaper();

  if (markRead) {
    await client.rpc("gpsl_sport_mark_read", { p_edition_id: editionId });
    await refreshGpslSportNav(client, { preserveViewingEdition });
  }

  return true;
}

export async function openGpslSport(supabase) {
  const client = supabase || sportSupabase || window.supabase;
  if (!client) {
    alert("GPSL Sport: not signed in.");
    return;
  }

  ensureSportModal();

  const paper = document.getElementById("gpslSportPaper");
  if (paper) {
    paper.innerHTML =
      '<div class="gpsl-sport-loading"><span class="gpsl-sport-loading-spinner"></span> Printing edition…</div>';
  }
  showSportModal();

  if (!sportEditionId) sportEditionId = readEditionIdFromNavButton();
  if (!sportEditionId) await refreshGpslSportNav(client);
  if (!sportEditionId) sportEditionId = readEditionIdFromNavButton();
  if (!sportEditionId) {
    hideSportModal();
    alert("No GPSL Sport edition is available yet.");
    return;
  }

  const ok = await loadSportEdition(sportEditionId, { markRead: true });
  if (!ok) {
    hideSportModal();
    alert("Could not load this edition.");
  }
}

export function closeGpslSport() {
  hideSportModal();
}

export async function initGpslSportUi(supabase) {
  sportSupabase = supabase || window.supabase;
  ensureSportModal();
  await refreshGpslSportNav(sportSupabase);
}
