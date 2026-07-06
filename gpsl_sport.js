/**
 * GPSL Sport — weekly newspaper modal
 */

let sportModalMounted = false;
let sportEditionId = null;
let sportActivePage = "front";

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

function ensureSportModal() {
  if (document.getElementById("gpslSportModal")) return;

  const overlay = document.createElement("div");
  overlay.id = "gpslSportModal";
  overlay.className = "gpsl-sport-modal";
  overlay.hidden = true;
  overlay.innerHTML = `
    <div class="gpsl-sport-dialog" role="dialog" aria-modal="true" aria-labelledby="gpslSportTitle">
      <button type="button" class="gpsl-sport-close" id="gpslSportClose" aria-label="Close newspaper">×</button>
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

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !overlay.hidden) closeGpslSport();
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

export async function refreshGpslSportNav(supabase) {
  const btn = document.getElementById("gpslSportNavBtn");
  if (!btn || !supabase) return;

  try {
    const { data, error } = await supabase.rpc("gpsl_sport_nav_state");
    if (error) throw error;

    if (!data?.has_edition) {
      btn.hidden = true;
      btn.classList.remove("has-unread");
      return;
    }

    btn.hidden = false;
    sportEditionId = data.edition_id;
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
  } catch (err) {
    console.warn("GPSL Sport nav:", err);
    btn.hidden = true;
  }
}

export async function openGpslSport(supabase) {
  if (!supabase || !sportEditionId) return;

  ensureSportModal();
  const overlay = document.getElementById("gpslSportModal");
  if (!overlay) return;

  const { data, error } = await supabase.rpc("gpsl_sport_get_edition", {
    p_edition_id: sportEditionId,
  });

  if (error || !data?.ok) {
    console.error("GPSL Sport load:", error || data);
    alert("Could not load this edition. Run gpsl_sport_phase1.sql in Supabase if this is new.");
    return;
  }

  window.__gpslSportEdition = data.edition;
  sportActivePage = "front";

  const backTab = document.getElementById("gpslSportBackTab");
  const backEnabled = !!data.edition?.back_page?.enabled;
  if (backTab) backTab.hidden = !backEnabled;

  overlay.querySelectorAll(".gpsl-sport-tab").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === "front");
  });

  renderSportPaper();
  overlay.hidden = false;
  document.body.classList.add("gpsl-sport-open");

  await supabase.rpc("gpsl_sport_mark_read", { p_edition_id: sportEditionId });
  refreshGpslSportNav(supabase);
}

export function closeGpslSport() {
  const overlay = document.getElementById("gpslSportModal");
  if (overlay) overlay.hidden = true;
  document.body.classList.remove("gpsl-sport-open");
}

export function renderNavGpslSportButton() {
  return (
    `<button type="button" id="gpslSportNavBtn" class="nav-shortcut nav-gpsl-sport" hidden ` +
    `title="GPSL Sport" aria-label="GPSL Sport newspaper">` +
    `<span class="nav-gpsl-sport-icon" aria-hidden="true">📰</span>` +
    `<span class="nav-gpsl-sport-label">GPSL Sport</span>` +
    `</button>`
  );
}

export async function initGpslSportUi(supabase) {
  if (sportModalMounted) {
    await refreshGpslSportNav(supabase);
    return;
  }
  sportModalMounted = true;
  ensureSportModal();

  const btn = document.getElementById("gpslSportNavBtn");
  if (btn) {
    btn.addEventListener("click", () => openGpslSport(supabase));
  }

  await refreshGpslSportNav(supabase);
}
