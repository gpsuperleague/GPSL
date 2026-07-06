/**
 * GPSL Sport — weekly newspaper modal
 */

let sportEditionId = null;
let sportActivePage = "front";
let sportSupabase = null;
let sportArchive = [];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatParagraphs(text) {
  return escapeHtml(text || "")
    .split(/\n\n+/)
    .map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`)
    .join("");
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

function renderSportPaper() {
  const paper = document.getElementById("gpslSportPaper");
  const edition = window.__gpslSportEdition;
  if (!paper || !edition) return;

  const front = edition.front_page || {};
  const back = edition.back_page || {};
  const stories = Array.isArray(front.stories) ? front.stories : [];
  const backStories = Array.isArray(back.stories) ? back.stories : [];

  if (sportActivePage === "back" && back.enabled) {
    const lead = back.lead || {};
    paper.innerHTML = `
      <header class="gpsl-sport-masthead gpsl-sport-masthead-back">
        <div class="gpsl-sport-masthead-name">GPSL Sport</div>
        <div class="gpsl-sport-masthead-edition">${escapeHtml(back.page_title || "Transfer special")} · ${escapeHtml(edition.edition_label)}</div>
      </header>
      <article class="gpsl-sport-lead">
        <h1 class="gpsl-sport-headline">${escapeHtml(lead.headline)}</h1>
        <div class="gpsl-sport-body">${formatParagraphs(lead.body)}</div>
      </article>
      ${
        backStories.length
          ? `<section class="gpsl-sport-more"><h2>Also on the move</h2>${backStories
              .map(
                (s) => `
            <article class="gpsl-sport-story gpsl-sport-story-small">
              <h3>${escapeHtml(s.headline)}</h3>
              <div class="gpsl-sport-body">${formatParagraphs(s.body)}</div>
            </article>`
              )
              .join("")}</section>`
          : ""
      }
    `;
    return;
  }

  paper.innerHTML = `
    <header class="gpsl-sport-masthead">
      <div class="gpsl-sport-masthead-name">${escapeHtml(front.masthead || "GPSL Sport")}</div>
      <div class="gpsl-sport-masthead-edition">${escapeHtml(edition.edition_label || front.edition_label)} Edition</div>
    </header>
    <article class="gpsl-sport-lead">
      <h1 class="gpsl-sport-headline">${escapeHtml(front.headline)}</h1>
      <p class="gpsl-sport-subhead">${escapeHtml(front.subhead)}</p>
      <div class="gpsl-sport-body">${formatParagraphs(front.lead_paragraph)}</div>
    </article>
    ${
      stories.length
        ? `<section class="gpsl-sport-more"><h2>Elsewhere this month</h2>${stories
            .map(
              (s) => `
          <article class="gpsl-sport-story">
            <div class="gpsl-sport-kicker">${escapeHtml(s.kicker)}</div>
            <h3>${escapeHtml(s.headline)}</h3>
            <div class="gpsl-sport-body">${formatParagraphs(s.body)}</div>
          </article>`
            )
            .join("")}</section>`
        : ""
    }
  `;
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
    console.warn("GPSL Sport: no supabase client");
    alert("GPSL Sport: not signed in.");
    return;
  }

  ensureSportModal();

  const paper = document.getElementById("gpslSportPaper");
  if (paper) paper.innerHTML = '<p class="gpsl-sport-loading">Loading edition…</p>';
  showSportModal();

  if (!sportEditionId) {
    sportEditionId = readEditionIdFromNavButton();
  }
  if (!sportEditionId) {
    await refreshGpslSportNav(client);
  }
  if (!sportEditionId) {
    sportEditionId = readEditionIdFromNavButton();
  }
  if (!sportEditionId) {
    hideSportModal();
    alert("No GPSL Sport edition is available yet.");
    return;
  }

  const ok = await loadSportEdition(sportEditionId, { markRead: true });
  if (!ok) {
    hideSportModal();
    alert("Could not load this edition. Run gpsl_sport_phase1.sql in Supabase if this is new.");
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
