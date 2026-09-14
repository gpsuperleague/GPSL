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

function reportBtnHtml(fixtureId, side, enabled) {
  if (!enabled) return "";
  return (
    `<button type="button" class="mv-report" data-mv-report="1" ` +
    `data-fixture-id="${escapeAttr(fixtureId)}" data-side="${escapeAttr(side)}" ` +
    `title="Report a breach in this ${side} video" aria-label="Report ${side} video">R</button>`
  );
}

/**
 * Compact home/away ticks for fixtures score cell.
 * @param {{ home_url?: string|null, away_url?: string|null }|null|undefined} videos
 * @param {{
 *   fixtureId?: number|string,
 *   fixture?: { home_club_short_name?: string, away_club_short_name?: string },
 *   myClubShort?: string|null,
 *   allowReport?: boolean
 * }} [opts]
 */
export function matchVideoTicksHtml(videos, opts = {}) {
  const v = videos || {};
  const fixtureId = opts.fixtureId ?? opts.fixture?.id;
  const allowReport = Boolean(opts.allowReport && fixtureId && opts.myClubShort);
  const my = upper(opts.myClubShort);
  const homeClub = upper(opts.fixture?.home_club_short_name);
  const awayClub = upper(opts.fixture?.away_club_short_name);

  const canHome = allowReport && Boolean(v.home_url) && my && my !== homeClub;
  const canAway = allowReport && Boolean(v.away_url) && my && my !== awayClub;

  return (
    `<span class="mv-ticks">` +
    `${tickHtml("H", v.home_url)}${reportBtnHtml(fixtureId, "home", canHome)}` +
    `${tickHtml("A", v.away_url)}${reportBtnHtml(fixtureId, "away", canAway)}` +
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
.mv-ticks { display:inline-flex; gap:3px; margin-left:6px; vertical-align:middle; font-size:11px; align-items:center; flex-wrap:wrap; }
.mv-tick { text-decoration:none; padding:1px 4px; border-radius:3px; font-weight:600; letter-spacing:0.02em; }
.mv-tick-on { color:#1a1a1a; background:#8d8; border:1px solid #6a6; }
.mv-tick-on:hover { filter:brightness(1.08); }
.mv-tick-off { color:#777; background:#222; border:1px solid #444; }
.mv-report {
  width:18px; height:18px; padding:0; margin:0;
  border-radius:50%; border:1px solid #c90; background:#2a2200; color:#fc6;
  font-size:10px; font-weight:700; line-height:1; cursor:pointer;
}
.mv-report:hover { background:#3a3000; border-color:#fc6; }
.mv-report-modal-backdrop {
  position:fixed; inset:0; background:rgba(0,0,0,0.65); z-index:12000;
  display:flex; align-items:center; justify-content:center; padding:16px;
}
.mv-report-modal {
  width:min(440px, 100%); background:#161616; border:1px solid #444; border-radius:8px;
  padding:16px 18px; color:#ddd; box-shadow:0 12px 40px rgba(0,0,0,0.45);
}
.mv-report-modal h3 { margin:0 0 8px; color:#ffcc66; font-size:16px; }
.mv-report-modal p { margin:0 0 12px; font-size:13px; color:#aaa; line-height:1.4; }
.mv-report-modal label { display:grid; gap:4px; font-size:13px; margin-bottom:10px; }
.mv-report-modal select, .mv-report-modal textarea {
  width:100%; box-sizing:border-box; padding:8px 10px;
  background:#1a1a1a; border:1px solid #333; color:#eee; border-radius:4px; font:inherit;
}
.mv-report-modal textarea { min-height:72px; resize:vertical; }
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
    const fixture = opts.resolveFixture?.(fixtureId);
    if (!fixtureId || !side) return;

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
        <h3 id="mvReportTitle">Report match video breach</h3>
        <p>
          ${escapeHtml(String(accused || side).toUpperCase())} · ${escapeHtml(side)} video
          ${fixture?.matchday != null ? ` · MD${escapeHtml(fixture.matchday)}` : ""}
        </p>
        <label>Breach
          <select id="mvReportBreach">
            <option value="">Select breach…</option>
            ${codes
              .map(
                (c) =>
                  `<option value="${escapeAttr(c.code)}">${escapeHtml(c.label)} (${escapeHtml(
                    c.category
                  )})</option>`
              )
              .join("")}
          </select>
        </label>
        <label>Note (optional — timestamp / detail)
          <textarea id="mvReportNote" maxlength="800" placeholder="e.g. 63' illegal PA"></textarea>
        </label>
        <div class="mv-report-actions">
          <button type="button" class="primary" id="mvReportSubmit">Submit report</button>
          <button type="button" id="mvReportCancel">Cancel</button>
        </div>
        <div class="mv-report-status" id="mvReportStatus"></div>
      </div>
    `;
    document.body.appendChild(backdrop);

    backdrop.addEventListener("click", (e) => {
      if (e.target === backdrop) closeReportModal();
    });
    backdrop.querySelector("#mvReportCancel")?.addEventListener("click", closeReportModal);

    backdrop.querySelector("#mvReportSubmit")?.addEventListener("click", async () => {
      const statusEl = backdrop.querySelector("#mvReportStatus");
      const code = backdrop.querySelector("#mvReportBreach")?.value;
      const note = backdrop.querySelector("#mvReportNote")?.value || "";
      if (!code) {
        if (statusEl) {
          statusEl.className = "mv-report-status err";
          statusEl.textContent = "Choose a breach.";
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
        p_breach_tariff_code: code,
        p_note: note || null,
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
            data?.reason === "duplicate_open_report"
              ? "You already have an open report for this breach on this video."
              : data?.reason || "Submit failed";
        }
        return;
      }
      if (statusEl) {
        statusEl.className = "mv-report-status ok";
        statusEl.textContent = "Report submitted — staff will review.";
      }
      setTimeout(closeReportModal, 900);
    });
  });
}
