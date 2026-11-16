/**
 * Fixture match video ticks (home / away Discord uploads) + breach report (R).
 */
import { ownerTagForClub } from "./clubs_lookup.js";

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {Array<number|string>} fixtureIds
 * @returns {Promise<Map<string, { home_url?: string|null, away_url?: string|null }>>}
 */
export async function loadFixtureMatchVideos(supabase, fixtureIds) {
  const map = new Map();
  const ids = [...new Set((fixtureIds || []).map((id) => Number(id)).filter(Boolean))];
  if (!ids.length) return map;

  const { data, error } = await supabase
    .from("fixture_match_videos")
    .select("fixture_id, side, video_url")
    .in("fixture_id", ids);

  if (error) {
    console.warn("loadFixtureMatchVideos:", error.message);
  }

  for (const row of data || []) {
    const key = String(row.fixture_id);
    const cur = map.get(key) || {
      home_url: null,
      away_url: null,
      home_pending: false,
      away_pending: false,
    };
    if (row.side === "home") cur.home_url = row.video_url;
    if (row.side === "away") cur.away_url = row.video_url;
    map.set(key, cur);
  }

  // Early Discord uploads held until the GPSL result is confirmed
  try {
    const { data: pending, error: pendErr } = await supabase.rpc(
      "match_video_pending_sides",
      { p_fixture_ids: ids }
    );
    if (pendErr) {
      if (pendErr.code !== "PGRST202") {
        console.warn("match_video_pending_sides:", pendErr.message);
      }
    } else {
      for (const row of pending || []) {
        const key = String(row.fixture_id);
        const cur = map.get(key) || {
          home_url: null,
          away_url: null,
          home_pending: false,
          away_pending: false,
        };
        if (row.side === "home" && !cur.home_url) {
          cur.home_url = row.video_url || "#";
          cur.home_pending = true;
        }
        if (row.side === "away" && !cur.away_url) {
          cur.away_url = row.video_url || "#";
          cur.away_pending = true;
        }
        map.set(key, cur);
      }
    }
  } catch (err) {
    console.warn("loadFixtureMatchVideos pending:", err);
  }

  return map;
}

function escapeAttr(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function upper(s) {
  return String(s || "").trim().toUpperCase();
}

/**
 * Pending-video tooltip: who must confirm, or that no result is in yet.
 * @param {object|null|undefined} fixture
 */
export function matchVideoPendingResultHint(fixture) {
  const status = String(fixture?.submission_status || "").toLowerCase();
  const submittedBy = upper(fixture?.submitted_by_club);
  const home = upper(fixture?.home_club_short_name);
  const away = upper(fixture?.away_club_short_name);

  if (status === "pending" && submittedBy) {
    let waitingClub = null;
    if (submittedBy === home && away) waitingClub = away;
    else if (submittedBy === away && home) waitingClub = home;
    if (waitingClub) {
      const owner = ownerTagForClub(waitingClub) || waitingClub;
      return `waiting for ${owner} to confirm the result`;
    }
    return "waiting for opponent to confirm the result";
  }

  if (String(fixture?.status || "").toLowerCase() === "played") {
    return "GPSL result confirmed";
  }

  return "no result submitted";
}

function tickHtml(sideLabel, url, pending = false, pendingHint = "") {
  const has = Boolean(url);
  if (has && pending) {
    const href =
      url && url !== "#"
        ? ` href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer"`
        : "";
    const why = pendingHint || "no result submitted";
    return `<a class="mv-tick mv-tick-pending"${href} title="${escapeAttr(
      `${sideLabel} video received — ${why}`
    )}">${sideLabel}⏳</a>`;
  }
  if (has) {
    return `<a class="mv-tick mv-tick-on" href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer" title="${sideLabel} video uploaded — open">${sideLabel}✓</a>`;
  }
  return `<span class="mv-tick mv-tick-off" title="${sideLabel} video not uploaded yet">${sideLabel}○</span>`;
}

function reportBtnHtml(fixtureId, side, mode, isOwn = false) {
  // mode: 'active' | 'no-video' | 'own' | 'locked' | 'clear'
  if (!mode) return "";
  let cls = "mv-report";
  let title = `Report breaches in this ${side} video`;
  let hasVideoAttr = "1";
  let ownAttr = isOwn ? "1" : "0";
  let lockedAttr = "0";
  let clearedAttr = "0";
  if (mode === "no-video") {
    cls = "mv-report mv-report-muted";
    title = `${side} has no video yet — upload required before reporting`;
    hasVideoAttr = "0";
  } else if (mode === "own") {
    cls = "mv-report mv-report-own";
    title = "Your club — you cannot report your own video";
  } else if (mode === "locked") {
    cls = "mv-report mv-report-locked";
    title = "This match side has already been reported (one report only)";
    hasVideoAttr = "0";
    lockedAttr = "1";
  } else if (mode === "clear") {
    cls = "mv-report mv-report-clear";
    title = "Admin check: no issues on this side. Others can still report.";
    clearedAttr = "1";
  }
  return (
    `<button type="button" class="${cls}" data-mv-report="1" ` +
    `data-fixture-id="${escapeAttr(fixtureId)}" data-side="${escapeAttr(side)}" ` +
    `data-has-video="${hasVideoAttr}" data-own="${ownAttr}" data-locked="${lockedAttr}" ` +
    `data-cleared="${clearedAttr}" ` +
    `title="${escapeAttr(title)}" aria-label="${escapeAttr(title)}">R</button>`
  );
}

function sideReportMode(url, isOwn, alreadyReported, adminCleared) {
  if (alreadyReported) return "locked";
  if (!url) return "no-video";
  if (isOwn && !adminCleared) return "own";
  if (adminCleared) return "clear";
  return "active";
}

/** Skip repeat RPCs after schema-cache miss (undeployed patch) so fixtures stay snappy. */
let matchVideoReportedSidesUnavailable = false;

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {Array<number|string>} fixtureIds
 * @returns {Promise<Set<string>>} keys `${fixtureId}:${side}`
 */
export async function loadMatchVideoReportedSides(supabase, fixtureIds) {
  const set = new Set();
  if (matchVideoReportedSidesUnavailable) return set;

  const ids = [...new Set((fixtureIds || []).map((id) => Number(id)).filter(Boolean))];
  if (!ids.length) return set;

  const { data, error } = await supabase.rpc("match_video_reported_sides", {
    p_fixture_ids: ids,
  });
  if (error) {
    const msg = String(error.message || error.code || "");
    const missing =
      error.code === "PGRST202" ||
      error.code === "42883" ||
      /could not find the function|schema cache|404/i.test(msg);
    if (missing) {
      matchVideoReportedSidesUnavailable = true;
      console.warn(
        "loadMatchVideoReportedSides: RPC missing — apply supabase/sql/patches/match_video_reported_sides_20260924.sql (further calls skipped this session)"
      );
    } else {
      console.warn("loadMatchVideoReportedSides:", msg);
    }
    return set;
  }
  const rows = Array.isArray(data) ? data : data ? [data].flat() : [];
  for (const row of rows) {
    if (row?.fixture_id != null && row?.side) {
      set.add(`${row.fixture_id}:${row.side}`);
    }
  }
  return set;
}

/** Skip repeat RPCs after schema-cache miss (undeployed patch) so fixtures stay snappy. */
let matchVideoAdminClearUnavailable = false;

/**
 * Sides an admin has marked checked. Non-admins always get an empty set.
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {Array<number|string>} fixtureIds
 * @returns {Promise<Set<string>>} keys `${fixtureId}:${side}`
 */
export async function loadMatchVideoAdminClearedSides(supabase, fixtureIds) {
  const set = new Set();
  if (matchVideoAdminClearUnavailable) return set;

  const ids = [...new Set((fixtureIds || []).map((id) => Number(id)).filter(Boolean))];
  if (!ids.length) return set;

  const { data, error } = await supabase.rpc("match_video_admin_cleared_sides", {
    p_fixture_ids: ids,
  });
  if (error) {
    const msg = String(error.message || error.code || "");
    const missing =
      error.code === "PGRST202" ||
      error.code === "42883" ||
      /could not find the function|schema cache|404/i.test(msg);
    if (missing) {
      matchVideoAdminClearUnavailable = true;
      console.warn("loadMatchVideoAdminClearedSides: RPC missing");
    } else {
      console.warn("loadMatchVideoAdminClearedSides:", msg);
    }
    return set;
  }
  const rows = Array.isArray(data) ? data : [];
  for (const row of rows) {
    if (row?.fixture_id != null && row?.side) {
      set.add(`${row.fixture_id}:${row.side}`);
    }
  }
  return set;
}

/**
 * Compact home/away ticks for fixtures score cell.
 * Always H+R / A+R on played fixtures (own / locked R stays visible).
 */
export function matchVideoTicksHtml(videos, opts = {}) {
  const v = videos || {};
  const fixtureId = opts.fixtureId ?? opts.fixture?.id;
  const allowReport = Boolean(opts.allowReport && fixtureId);
  const my = upper(opts.myClubShort);
  const homeClub = upper(opts.fixture?.home_club_short_name);
  const awayClub = upper(opts.fixture?.away_club_short_name);
  const played =
    String(opts.fixture?.status || "").toLowerCase() === "played" ||
    opts.fixture?.home_goals != null ||
    opts.fixture?.away_goals != null;
  /** @type {Set<string>|Map<string, unknown>|null|undefined} */
  const reported = opts.reportedSides;
  const adminView = opts.adminView === true;
  const cleared = adminView ? opts.clearedSides : null;

  const sideMarked = (bag, side) => {
    if (!bag) return false;
    const key = `${fixtureId}:${side}`;
    if (bag instanceof Set) return bag.has(key);
    if (typeof bag.has === "function") return bag.has(key);
    return Boolean(bag[key]);
  };
  const isReported = (side) => sideMarked(reported, side);
  const isCleared = (side) => adminView && sideMarked(cleared, side) && !isReported(side);

  const showReports = allowReport && (played || v.home_url || v.away_url);
  const homeOwn = Boolean(my && homeClub && my === homeClub);
  const awayOwn = Boolean(my && awayClub && my === awayClub);

  const homeReport = showReports
    ? reportBtnHtml(
        fixtureId,
        "home",
        sideReportMode(v.home_url, homeOwn, isReported("home"), isCleared("home")),
        homeOwn
      )
    : "";
  const awayReport = showReports
    ? reportBtnHtml(
        fixtureId,
        "away",
        sideReportMode(v.away_url, awayOwn, isReported("away"), isCleared("away")),
        awayOwn
      )
    : "";

  const pendingHint = matchVideoPendingResultHint(opts.fixture);

  return (
    `<span class="mv-ticks">` +
    `<span class="mv-side">${tickHtml(
      "H",
      v.home_url,
      v.home_pending,
      pendingHint
    )}${homeReport}</span>` +
    `<span class="mv-side">${tickHtml(
      "A",
      v.away_url,
      v.away_pending,
      pendingHint
    )}${awayReport}</span>` +
    `</span>`
  );
}

/** Suggested Discord filename for a fixture (copy hint). */
export function matchVideoFilenameHint(fixture) {
  if (!fixture) return "";
  const home = String(fixture.home_club_short_name || "").toUpperCase();
  const away = String(fixture.away_club_short_name || "").toUpperCase();
  const hg = fixture.home_goals != null ? fixture.home_goals : "0";
  const ag = fixture.away_goals != null ? fixture.away_goals : "0";

  let tag = "SL-MD1";
  if (fixture.competition_type === "cup") {
    const cupMap = {
      super8: "S8",
      plate: "PL",
      shield: "SH",
      bowl: "BO",
      league_cup: "LC",
    };
    const comp = cupMap[fixture.cup_code] || "S8";
    const round = fixture.cup_round != null ? `R${fixture.cup_round}` : "R1";
    tag = `${comp}-${round}`;
  } else if (fixture.division === "superleague") {
    tag = `SL-MD${fixture.matchday || "?"}`;
  } else if (fixture.division === "championship_a") {
    tag = `CA-MD${fixture.matchday || "?"}`;
  } else if (fixture.division === "championship_b") {
    tag = `CB-MD${fixture.matchday || "?"}`;
  } else {
    tag = `CH-MD${fixture.matchday || "?"}`;
  }

  return `${home} ${hg}-${ag} ${away} [${tag}]`;
}

export const MATCH_VIDEO_TICK_CSS = `
.mv-ticks {
  display:inline-flex; flex-direction:column; gap:2px;
  margin-left:6px; vertical-align:middle; font-size:11px;
  align-items:flex-start;
}
.mv-side { display:inline-flex; gap:4px; align-items:center; }
.mv-tick { text-decoration:none; padding:1px 4px; border-radius:3px; font-weight:600; letter-spacing:0.02em; }
.mv-tick-on { color:#1a1a1a; background:#8d8; border:1px solid #6a6; }
.mv-tick-on:hover { filter:brightness(1.08); }
.mv-tick-pending { color:#1a1a1a; background:#fc6; border:1px solid #c96; text-decoration:none; }
.mv-tick-pending:hover { filter:brightness(1.05); }
.mv-tick-off { color:#777; background:#222; border:1px solid #444; }
.mv-report {
  display:inline-flex; align-items:center; justify-content:center;
  width:20px; height:20px; min-width:20px; padding:0; margin:0;
  border-radius:50%; border:2px solid #e6a000; background:#3a2a00; color:#ffcc33;
  font-size:11px; font-weight:800; line-height:1; cursor:pointer;
  font-family:inherit; box-shadow:0 0 0 1px rgba(0,0,0,0.35);
}
.mv-report:hover { background:#5a4200; border-color:#ffcc33; color:#fff3a0; }
.mv-report-muted {
  border-color:#666; background:#222; color:#888; cursor:pointer; opacity:0.85;
}
.mv-report-muted:hover { border-color:#999; color:#bbb; background:#2a2a2a; }
.mv-report-own {
  border-color:#555; background:#1a1a1a; color:#555; cursor:default; opacity:0.55;
}
.mv-report-own:hover { border-color:#555; background:#1a1a1a; color:#555; }
.mv-report-locked {
  border-color:#446; background:#1a1a28; color:#889; cursor:default; opacity:0.7;
}
.mv-report-locked:hover { border-color:#446; background:#1a1a28; color:#889; }
.mv-report-clear {
  border-color:#6c6; background:#143214; color:#b6f5b6;
}
.mv-report-clear:hover { background:#1c4020; border-color:#8d8; color:#fff; }
.mv-admin-clear {
  display:flex; gap:8px; align-items:flex-start; margin:0 0 12px;
  padding:10px 12px; border:1px solid #365; border-radius:6px; background:#102018;
  font-size:13px; color:#cfe;
}
.mv-report-modal {
  width:min(520px, 100%); max-height:min(90vh, 720px); overflow:auto;
  background:#161616; border:1px solid #444; border-radius:8px;
  padding:16px 18px; color:#ddd; box-shadow:0 12px 40px rgba(0,0,0,0.45);
}
.mv-breach-list { display:grid; gap:8px; margin:0 0 12px; max-height:340px; overflow:auto; }
.mv-breach-row {
  border:1px solid #333; border-radius:6px; padding:8px 10px; background:#1a1a1a;
}
.mv-breach-row label.check {
  display:flex; gap:8px; align-items:flex-start; font-size:13px; color:#ddd; margin:0;
}
.mv-breach-row .mv-breach-note {
  margin-top:8px; display:none; width:100%; box-sizing:border-box;
  padding:8px 10px; background:#111; border:1px solid #333; color:#eee; border-radius:4px;
  font:inherit; min-height:56px; resize:vertical;
}
.mv-breach-row.is-on .mv-breach-note { display:block; }
.mv-breach-row .mv-drag-count { display:none; margin-top:8px; font-size:13px; color:#ddd; }
.mv-breach-row.is-on .mv-drag-count { display:block; }
.mv-breach-row .mv-drag-count input { margin-left:8px; width:64px; padding:4px 6px; background:#111; border:1px solid #333; color:#eee; }
.mv-breach-row .note { display:none; }
.mv-breach-row.is-on .note { display:block; }
.mv-report-modal-backdrop {
  position:fixed; inset:0; background:rgba(0,0,0,0.65); z-index:12000;
  display:flex; align-items:center; justify-content:center; padding:16px;
}
.mv-report-modal h3 { margin:0 0 8px; color:var(--gpsl-accent-hover, #ffcc66); font-size:16px; }
.mv-report-modal p { margin:0 0 12px; font-size:13px; color:#aaa; line-height:1.4; }
.mv-report-actions { display:flex; gap:8px; flex-wrap:wrap; margin-top:12px; }
.mv-report-actions button {
  padding:8px 12px; border-radius:4px; border:1px solid #555; background:#333; color:#eee; cursor:pointer;
}
.mv-report-actions button.primary { background:#c60; border-color:#e80; color:#111; font-weight:600; }
.mv-report-status { margin-top:10px; font-size:13px; min-height:1.2em; }
.mv-report-status.ok { color:#8d8; }
.mv-report-status.err { color:#f88; }
`;

let breachCodesCache = null;

async function loadBreachCodes(supabase) {
  if (breachCodesCache) return breachCodesCache;
  const { data, error } = await supabase.rpc("match_video_report_breach_codes");
  if (error) throw error;
  breachCodesCache = Array.isArray(data) ? data : [];
  return breachCodesCache;
}

function closeReportModal() {
  document.getElementById("mvReportModal")?.remove();
}

/**
 * Wire circled R buttons → report modal.
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {ParentNode} root
 * @param {{
 *   resolveFixture: (fixtureId: number) => object|null|undefined,
 *   formatMoney?: (n: number) => string
 * }} opts
 */
export function wireMatchVideoReportButtons(supabase, root, opts) {
  const host = root || document;
  host.addEventListener("click", async (ev) => {
    const btn = ev.target?.closest?.("[data-mv-report]");
    if (!btn) return;
    ev.preventDefault();
    ev.stopPropagation();

    const fixtureId = Number(btn.getAttribute("data-fixture-id"));
    const side = String(btn.getAttribute("data-side") || "");
    const hasVideo = btn.getAttribute("data-has-video") !== "0";
    const isOwn = btn.getAttribute("data-own") === "1";
    const isLocked = btn.getAttribute("data-locked") === "1";
    const fixture = opts.resolveFixture?.(fixtureId);
    if (!fixtureId || !side) return;

    if (isOwn && opts.isAdmin !== true) {
      alert("You cannot report your own club’s match video.");
      return;
    }
    if (isLocked) {
      alert(
        "This match side has already been reported.\n\nOnly one report is allowed — if it was rejected, it cannot be re-reported."
      );
      return;
    }
    if (!hasVideo) {
      alert(
        "That side has not uploaded a match video yet.\n\nYou can only report matchday breaches once their video is online (green tick)."
      );
      return;
    }

    closeReportModal();

    const adminView = opts.isAdmin === true;
    const checkOnly = adminView && isOwn;
    let codes = [];
    if (!checkOnly) {
      try {
        codes = await loadBreachCodes(supabase);
      } catch (err) {
        alert(err?.message || "Could not load breach list");
        return;
      }
    }

    const accused =
      side === "home"
        ? fixture?.home_club_short_name
        : fixture?.away_club_short_name;
    const alreadyClear = btn.getAttribute("data-cleared") === "1";

    const backdrop = document.createElement("div");
    backdrop.id = "mvReportModal";
    backdrop.className = "mv-report-modal-backdrop";
    backdrop.innerHTML = `
      <div class="mv-report-modal" role="dialog" aria-modal="true" aria-labelledby="mvReportTitle">
        <h3 id="mvReportTitle">${checkOnly ? "Admin video check" : "Report match video breaches"}</h3>
        <p>
          ${escapeHtml(String(accused || side).toUpperCase())} · ${escapeHtml(side)} video
          ${fixture?.matchday != null ? ` · MD${escapeHtml(fixture.matchday)}` : ""}
          ${
            checkOnly
              ? `<br>This is your club’s video, so you cannot file a report on it. You can still mark the side checked.`
              : `<br>Select every breach you can see — each one needs a note (e.g. timestamp). One report only per match side.
          <br>Includes display rules (e.g. <b>no individual player instructions</b>, <b>no dragging players</b> on a formation that must be set before the match, Red/Blue timing).
          <br>Staff are notified and must approve the report. Nothing changes until then.`
          }
        </p>
        ${
          adminView
            ? `<label class="mv-admin-clear">
                <input type="checkbox" id="mvAdminClear"${alreadyClear ? " checked" : ""}>
                <span>Checked, no issues. Owners do not see this, and they can still report this side.</span>
              </label>`
            : ""
        }
        ${
          checkOnly
            ? ""
            : `<div class="mv-breach-list" id="mvBreachList">
          ${codes
            .map(
              (c) => `
            <div class="mv-breach-row" data-code="${escapeAttr(c.code)}">
              <label class="check">
                <input type="checkbox" data-breach-check="${escapeAttr(c.code)}">
                <span>${escapeHtml(c.label)} <span style="color:#777">(${escapeHtml(
                  c.category
                )})</span></span>
              </label>
              <textarea class="mv-breach-note" data-breach-note="${escapeAttr(c.code)}"
                maxlength="800" placeholder="Required note — e.g. 63' / what you saw"></textarea>
              ${
                c.code === "formation_player_drag"
                  ? `<label class="mv-drag-count">Drags seen in this match
                      <input type="number" min="1" max="20" value="1" data-breach-instances="${escapeAttr(c.code)}">
                    </label>
                    <p class="note" style="margin:6px 0 0">Staff must approve. Won or drew → replay. Opponent won → result stands. 2 or more drags → −1 point as well.</p>`
                  : ""
              }
            </div>`
            )
            .join("")}
        </div>`
        }
        <div class="mv-report-actions">
          ${checkOnly ? "" : `<button type="button" class="primary" id="mvReportSubmit">Submit report</button>`}
          <button type="button" id="mvReportCancel">${checkOnly ? "Close" : "Cancel"}</button>
        </div>
        <div class="mv-report-status" id="mvReportStatus"></div>
      </div>
    `;
    document.body.appendChild(backdrop);

    const paintAdminClear = (want) => {
      btn.classList.toggle("mv-report-clear", want);
      btn.classList.toggle("mv-report-locked", false);
      btn.setAttribute("data-cleared", want ? "1" : "0");
      btn.setAttribute("data-locked", "0");
      const nextTitle = want
        ? "Admin check: no issues on this side. Others can still report."
        : `Report breaches in this ${side} video`;
      btn.title = nextTitle;
      btn.setAttribute("aria-label", nextTitle);
      if (typeof opts.onAdminClear === "function") {
        try {
          opts.onAdminClear({ fixtureId, side, cleared: want });
        } catch {
          /* ignore */
        }
      }
    };

    const saveAdminClear = async (want) => {
      const { error } = await supabase.rpc("match_video_admin_set_clear", {
        p_fixture_id: fixtureId,
        p_side: side,
        p_cleared: want,
      });
      if (error) return error;
      paintAdminClear(want);
      return null;
    };

    backdrop.querySelector("#mvAdminClear")?.addEventListener("change", async (e) => {
      const box = e.target;
      const want = box.checked === true;
      const statusEl = backdrop.querySelector("#mvReportStatus");
      box.disabled = true;
      if (statusEl) {
        statusEl.className = "mv-report-status";
        statusEl.textContent = want ? "Saving check…" : "Clearing check…";
      }
      const error = await saveAdminClear(want);
      box.disabled = false;
      if (error) {
        box.checked = !want;
        if (statusEl) {
          statusEl.className = "mv-report-status err";
          statusEl.textContent = error.message;
        }
        return;
      }
      if (statusEl) {
        statusEl.className = "mv-report-status ok";
        statusEl.textContent = want
          ? "Marked checked. The R button is green for admins."
          : "Check removed.";
      }
    });

    backdrop.querySelectorAll("[data-breach-check]").forEach((cb) => {
      cb.addEventListener("change", () => {
        const row = cb.closest(".mv-breach-row");
        if (!row) return;
        row.classList.toggle("is-on", cb.checked);
        if (cb.checked) {
          row.querySelector("[data-breach-note]")?.focus();
        }
      });
    });

    backdrop.addEventListener("click", (e) => {
      if (e.target === backdrop) closeReportModal();
    });
    backdrop.querySelector("#mvReportCancel")?.addEventListener("click", closeReportModal);

    backdrop.querySelector("#mvReportSubmit")?.addEventListener("click", async () => {
      const statusEl = backdrop.querySelector("#mvReportStatus");
      const breaches = [];
      for (const row of backdrop.querySelectorAll(".mv-breach-row")) {
        const code = row.getAttribute("data-code");
        const checked = row.querySelector("[data-breach-check]")?.checked;
        if (!checked) continue;
        const note = String(row.querySelector("[data-breach-note]")?.value || "").trim();
        if (!note) {
          if (statusEl) {
            statusEl.className = "mv-report-status err";
            statusEl.textContent = "Add a note for every selected breach.";
          }
          row.querySelector("[data-breach-note]")?.focus();
          return;
        }
        const instRaw = row.querySelector("[data-breach-instances]")?.value;
        const instances =
          code === "formation_player_drag"
            ? Math.max(1, Math.min(20, Number(instRaw) || 1))
            : undefined;
        breaches.push(
          instances != null ? { code, note, instances } : { code, note }
        );
      }
      if (!breaches.length) {
        const adminBox = backdrop.querySelector("#mvAdminClear");
        if (adminBox?.checked) {
          if (statusEl) {
            statusEl.className = "mv-report-status";
            statusEl.textContent = "Saving check…";
          }
          const clearError = await saveAdminClear(true);
          if (clearError) {
            if (statusEl) {
              statusEl.className = "mv-report-status err";
              statusEl.textContent = clearError.message;
            }
            return;
          }
          if (statusEl) {
            statusEl.className = "mv-report-status ok";
            statusEl.textContent = "Marked checked. The R button is green for admins.";
          }
          setTimeout(closeReportModal, 700);
          return;
        }
        if (statusEl) {
          statusEl.className = "mv-report-status err";
          statusEl.textContent = "Select at least one breach.";
        }
        return;
      }
      if (statusEl) {
        statusEl.className = "mv-report-status";
        statusEl.textContent = "Submitting…";
      }
      const { data, error } = await supabase.rpc("match_video_submit_breach_report", {
        p_fixture_id: fixtureId,
        p_side: side,
        p_breaches: breaches,
      });
      if (error) {
        if (statusEl) {
          statusEl.className = "mv-report-status err";
          statusEl.textContent = error.message;
        }
        return;
      }
      if (!data?.ok) {
        if (statusEl) {
          statusEl.className = "mv-report-status err";
          statusEl.textContent =
            data?.message ||
            (data?.reason === "already_reported"
              ? "This match side was already reported."
              : data?.reason || "Submit failed");
        }
        return;
      }
      if (typeof opts.onSubmitted === "function") {
        try {
          opts.onSubmitted({ fixtureId, side, reportId: data.report_id });
        } catch {
          /* ignore */
        }
      }
      if (statusEl) {
        statusEl.className = "mv-report-status ok";
        statusEl.textContent = `Report submitted (${breaches.length} breach${
          breaches.length === 1 ? "" : "es"
        }). Staff will review.`;
      }
      setTimeout(closeReportModal, 1000);
    });
  });
}
