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

function renderStoryCard(story, { compact = false } = {}) {
  const clubShort = story.club_short || story.club_short_name;
  const playerId = story.player_id ? String(story.player_id) : null;
  const badge = clubBadgeUrl(clubShort);
  const card = playerId ? pesdbPlayerCardUrl(playerId) : null;
  const stadium = !playerId && clubShort ? stadiumImageUrl(clubShort) : null;

  let media = "";
  if (card) {
    media = `<div class="gpsl-sport-story-media">${imgTag(card, "gpsl-sport-story-player", "")}</div>`;
  } else if (stadium) {
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

function renderSportPaper() {
  const paper = document.getElementById("gpslSportPaper");
  const edition = window.__gpslSportEdition;
  if (!paper || !edition) return;

  const front = edition.front_page || {};
  const back = edition.back_page || {};
  const ownerStories = Array.isArray(front.owner_stories) ? front.owner_stories : [];
  const backOwners = Array.isArray(back.owner_stories) ? back.owner_stories : [];
  const stories = Array.isArray(front.stories) ? front.stories : [];
  const backStories = Array.isArray(back.stories) ? back.stories : [];
  const hero = resolveHero(front, back, edition);
  const editionLabel = edition.edition_label || front.edition_label || "";

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

  const leadIsOwner =
    (front.story_type || "").includes("owner") && front.hero?.kind === "owner_takeover";
  const ownerSectionItems = leadIsOwner ? ownerStories.slice(1) : ownerStories;
  const railOwnerStories = leadIsOwner ? ownerStories.slice(1) : ownerStories;
  const railStories = [...railOwnerStories, ...stories].slice(0, 3);

  paper.innerHTML = `
    <div class="gpsl-sport-page">
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
          railStories.length
            ? `<aside class="gpsl-sport-rail">
                <h2 class="gpsl-sport-rail-title">In brief</h2>
                ${railStories.map((s) => renderStoryCard(s, { compact: true })).join("")}
              </aside>`
            : `<aside class="gpsl-sport-rail gpsl-sport-rail-empty">
                <h2 class="gpsl-sport-rail-title">Inside this edition</h2>
                <p class="gpsl-sport-rail-blurb">Boardroom moves, transfer fees and pre-season plotting across the GPSL.</p>
              </aside>`
        }
      </div>
      ${renderStorySection("New owners at the wheel", ownerSectionItems)}
      ${stories.length ? renderStorySection("Transfer wire", stories) : ""}
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
      <div class="gpsl-sport-tabs">
        <button type="button" class="gpsl-sport-tab active" data-page="front">Front page</button>
        <button type="button" class="gpsl-sport-tab" data-page="back" id="gpslSportBackTab" hidden>Back page</button>
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
    btn.addEventListener("click", () => {
      sportActivePage = btn.dataset.page || "front";
      overlay.querySelectorAll(".gpsl-sport-tab").forEach((b) => {
        b.classList.toggle("active", b.dataset.page === sportActivePage);
      });
      renderSportPaper();
    });
  });
  document.getElementById("gpslSportArchiveSelect")?.addEventListener("change", (e) => {
    const nextId = Number(e.target.value);
    if (!nextId || nextId === Number(sportEditionId)) return;
    loadSportEdition(nextId, { markRead: true });
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

export async function refreshGpslSportNav(supabase) {
  const btn = document.getElementById("gpslSportNavBtn");
  const client = supabase || sportSupabase || window.supabase;
  if (!btn || !client) return;

  try {
    const { data, error } = await client.rpc("gpsl_sport_nav_state");
    if (error) throw error;

    if (!data?.has_edition) {
      btn.hidden = true;
      btn.removeAttribute("data-edition-id");
      btn.classList.remove("has-unread");
      sportEditionId = null;
      return;
    }

    btn.hidden = false;
    sportEditionId = data.edition_id;
    btn.dataset.editionId = String(data.edition_id);
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

async function loadSportEdition(editionId, { markRead = false } = {}) {
  const client = sportSupabase || window.supabase;
  if (!client || !editionId) return false;

  sportEditionId = editionId;
  const btn = document.getElementById("gpslSportNavBtn");
  if (btn) btn.dataset.editionId = String(editionId);

  const { data, error } = await client.rpc("gpsl_sport_get_edition", {
    p_edition_id: editionId,
  });

  if (error || !data?.ok) {
    console.error("GPSL Sport load:", error || data);
    return false;
  }

  window.__gpslSportEdition = data.edition;
  sportActivePage = "front";

  const overlay = document.getElementById("gpslSportModal");
  const backTab = document.getElementById("gpslSportBackTab");
  const backEnabled = !!data.edition?.back_page?.enabled;
  if (backTab) backTab.hidden = !backEnabled;

  overlay?.querySelectorAll(".gpsl-sport-tab").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === "front");
  });

  renderSportArchiveSelect();
  renderSportPaper();

  if (markRead) {
    await client.rpc("gpsl_sport_mark_read", { p_edition_id: editionId });
    refreshGpslSportNav(client);
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
