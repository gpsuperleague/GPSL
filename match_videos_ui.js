/**
 * Fixture match video ticks (home / away Discord uploads) + breach report (R).
 */

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
    return map;
  }

  for (const row of data || []) {
    const key = String(row.fixture_id);
    const cur = map.get(key) || { home_url: null, away_url: null };
    if (row.side === "home") cur.home_url = row.video_url;
    if (row.side === "away") cur.away_url = row.video_url;
    map.set(key, cur);
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

function tickHtml(sideLabel, url) {
  const has = Boolean(url);
  if (has) {
    return `<a class="mv-tick mv-tick-on" href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer" title="${sideLabel} video uploaded — open">${sideLabel}✓</a>`;
  }
  return `<span class="mv-tick mv-tick-off" title="${sideLabel} video not uploaded yet">${sideLabel}○</span>`;
}

function reportBtnHtml(fixtureId, side, mode) {
  // mode: 'active' | 'no-video' | 'own' | 'locked'
  if (!mode) return "";
  let cls = "mv-report";
  let title = `Report breaches in this ${side} video`;
  let hasVideoAttr = "1";
  let ownAttr = "0";
  let lockedAttr = "0";
  if (mode === "no-video") {
    cls = "mv-report mv-report-muted";
    title = `${side} has no video yet — upload required before reporting`;
    hasVideoAttr = "0";
  } else if (mode === "own") {
    cls = "mv-report mv-report-own";
    title = "Your club — you cannot report your own video";
    hasVideoAttr = "0";
    ownAttr = "1";
  } else if (mode === "locked") {
    cls = "mv-report mv-report-locked";
    title = "This match side has already been reported (one report only)";
    hasVideoAttr = "0";
    lockedAttr = "1";
  }
  return (
    `<button type="button" class="${cls}" data-mv-report="1" ` +
    `data-fixture-id="${escapeAttr(fixtureId)}" data-side="${escapeAttr(side)}" ` +
    `data-has-video="${hasVideoAttr}" data-own="${ownAttr}" data-locked="${lockedAttr}" ` +
    `title="${escapeAttr(title)}" aria-label="${escapeAttr(title)}">R</button>`
  );
}

function sideReportMode(url, isOwn, alreadyReported) {
  if (alreadyReported) return "locked";
  if (isOwn) return "own";
  return url ? "active" : "no-video";
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

  const isReported = (side) => {
    if (!reported) return false;
    const key = `${fixtureId}:${side}`;
    if (reported instanceof Set) return reported.has(key);
    if (typeof reported.has === "function") return reported.has(key);
    return Boolean(reported[key]);
  };

  const showReports = allowReport && (played || v.home_url || v.away_url);
  const homeOwn = Boolean(my && homeClub && my === homeClub);
  const awayOwn = Boolean(my && awayClub && my === awayClub);

  const homeReport = showReports
    ? reportBtnHtml(
        fixtureId,
        "home",
        sideReportMode(v.home_url, homeOwn, isReported("home"))
      )
    : "";
  const awayReport = showReports
    ? reportBtnHtml(
        fixtureId,
        "away",
        sideReportMode(v.away_url, awayOwn, isReported("away"))
      )
    : "";

  return (
    `<span class="mv-ticks">` +
    `<span class="mv-side">${tickHtml("H", v.home_url)}${homeReport}</span>` +
    `<span class="mv-side">${tickHtml("A", v.away_url)}${awayReport}</span>` +
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
.mv-report-modal-backdrop {
  position:fixed; inset:0; background:rgba(0,0,0,0.65); z-index:12000;
  display:flex; align-items:center; justify-content:center; padding:16px;
}
.mv-report-modal h3 { margin:0 0 8px; color:#ffcc66; font-size:16px; }
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

    if (isOwn) {
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

    let codes = [];
    try {
      codes = await loadBreachCodes(supabase);
    } catch (err) {
      alert(err?.message || "Could not load breach list");
      return;
    }

    const accused =
      side === "home"
        ? fixture?.home_club_short_name
        : fixture?.away_club_short_name;

    const backdrop = document.createElement("div");
    backdrop.id = "mvReportModal";
    backdrop.className = "mv-report-modal-backdrop";
    backdrop.innerHTML = `
      <div class="mv-report-modal" role="dialog" aria-modal="true" aria-labelledby="mvReportTitle">
        <h3 id="mvReportTitle">Report match video breaches</h3>
        <p>
          ${escapeHtml(String(accused || side).toUpperCase())} · ${escapeHtml(side)} video
          ${fixture?.matchday != null ? ` · MD${escapeHtml(fixture.matchday)}` : ""}
          <br>Select every breach you can see — each one needs a note (e.g. timestamp). One report only per match side.
        </p>
        <div class="mv-breach-list" id="mvBreachList">
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
            </div>`
            )
            .join("")}
        </div>
        <div class="mv-report-actions">
          <button type="button" class="primary" id="mvReportSubmit">Submit report</button>
          <button type="button" id="mvReportCancel">Cancel</button>
        </div>
        <div class="mv-report-status" id="mvReportStatus"></div>
      </div>
    `;
    document.body.appendChild(backdrop);

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
        breaches.push({ code, note });
      }
      if (!breaches.length) {
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
