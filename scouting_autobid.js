import { formatMoney } from "./competition.js";

/**
 * Away-mode auto-bid plan for a dated player draft (Scouting → Target lists).
 * Server side: player_draft_autobid_* RPCs + the per-minute cron engine.
 */

const STATE_LABELS = {
  pending: "Waiting for the draft",
  waiting_credits: "Waiting for a credit",
  waiting_open: "Waiting for a club to open it",
  leading: "Leading",
  in_play: "In — max bid defending",
  beaten: "Beaten above your max",
  priced_out: "Price above your max",
  skipped: "Skipped",
  cutoff: "Missed — cutoff passed",
  ineligible: "Can't be bid on",
  owned: "Already in your squad",
  won: "Won / leading at close",
  lost: "Outbid",
  excluded: "Excluded",
};

const STATE_TONE = {
  leading: "ok",
  won: "ok",
  in_play: "warn",
  waiting_credits: "warn",
  waiting_open: "warn",
  beaten: "bad",
  priced_out: "bad",
  lost: "bad",
  ineligible: "bad",
  cutoff: "bad",
  skipped: "muted",
  excluded: "muted",
  owned: "muted",
  pending: "muted",
};

const PLAN_STATUS_LABELS = {
  scheduled: "Scheduled — starts when the draft opens",
  live: "Live — working now",
  finished: "Finished",
  expired: "Expired (draft did not run)",
};

const ROUND_TO = 500000;

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function toMillions(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v <= 0) return "";
  return String(Math.round((v / 1e6) * 100) / 100);
}

function fromMillions(s) {
  const v = Number(String(s ?? "").replace(/,/g, "").trim());
  if (!Number.isFinite(v) || v <= 0) return null;
  return Math.round((v * 1e6) / ROUND_TO) * ROUND_TO;
}

function fmtWhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    weekday: "short",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function injectStyles() {
  if (document.getElementById("scoutAutoBidStyles")) return;
  const style = document.createElement("style");
  style.id = "scoutAutoBidStyles";
  style.textContent = `
    .scout-ab-overlay { position: fixed; inset: 0; background: rgba(0,0,0,.65); z-index: 2000;
      display: flex; align-items: flex-start; justify-content: center; overflow-y: auto; padding: 32px 12px; }
    .scout-ab-overlay[hidden] { display: none; }
    .scout-ab-panel { background: #141a22; border: 1px solid #2c3a4a; border-radius: 10px; width: min(1080px, 100%);
      padding: 18px 20px; color: #e6e6e6; box-shadow: 0 12px 40px rgba(0,0,0,.5); }
    .scout-ab-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .scout-ab-head h2 { margin: 0; font-size: 18px; color: #ff9900; }
    .scout-ab-intro { font-size: 12.5px; color: #b8c2cc; margin: 8px 0 12px; line-height: 1.45; }
    .scout-ab-row { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 14px; margin: 8px 0; }
    .scout-ab-row label { font-size: 12.5px; color: #c9d3dd; }
    .scout-ab-row input[type="number"] { width: 110px; }
    .scout-ab-row select { min-width: 260px; }
    .scout-ab-status { font-size: 12.5px; padding: 6px 10px; border-radius: 6px; background: #1c2531; margin: 6px 0; }
    .scout-ab-status.bad { background: #3a1d1d; color: #ffb3b3; }
    .scout-ab-status.warn { background: #3a311a; color: #ffd98a; }
    .scout-ab-table { width: 100%; border-collapse: collapse; font-size: 12.5px; margin-top: 10px; }
    .scout-ab-table th, .scout-ab-table td { padding: 5px 6px; border-bottom: 1px solid #243040; text-align: left; vertical-align: middle; }
    .scout-ab-table th { color: #9fb0c0; font-weight: 600; font-size: 11.5px; text-transform: uppercase; letter-spacing: .03em; }
    .scout-ab-table tr.is-off td { opacity: .45; }
    .scout-ab-table input.scout-ab-max { width: 80px; }
    .scout-ab-table .scout-ab-warn { color: #ffb366; font-size: 11px; display: block; }
    .scout-ab-pill { display: inline-block; padding: 2px 7px; border-radius: 10px; font-size: 11.5px; background: #243040; }
    .scout-ab-pill.ok { background: #1d3a26; color: #9fe0b0; }
    .scout-ab-pill.warn { background: #3a311a; color: #ffd98a; }
    .scout-ab-pill.bad { background: #3a1d1d; color: #ffb3b3; }
    .scout-ab-pill.muted { background: #222a33; color: #9aa6b2; }
    .scout-ab-note { display: block; font-size: 11px; color: #9aa6b2; margin-top: 2px; }
    .scout-ab-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
    .scout-ab-mini { padding: 1px 6px; min-width: 0; font-size: 12px; line-height: 1.4; }
    .scout-ab-msg { font-size: 12.5px; margin-left: 6px; }
    .scout-ab-msg.ok { color: #9fe0b0; }
    .scout-ab-msg.bad { color: #ffb3b3; }
  `;
  document.head.appendChild(style);
}

function buildOverlay() {
  let overlay = document.getElementById("scoutAutoBidOverlay");
  if (overlay) return overlay;
  overlay = document.createElement("div");
  overlay.id = "scoutAutoBidOverlay";
  overlay.className = "scout-ab-overlay";
  overlay.hidden = true;
  overlay.innerHTML = `
    <div class="scout-ab-panel" role="dialog" aria-modal="true" aria-labelledby="scoutAbTitle">
      <div class="scout-ab-head">
        <h2 id="scoutAbTitle">🤖 Auto-bid plan (away mode)</h2>
        <button type="button" class="button secondary" id="scoutAbClose">Close</button>
      </div>
      <p class="scout-ab-intro">
        Away during a player draft? Pick the draft, set a <b>max bid</b> per target and the order you want them.
        While the draft is live the system works down your list every minute: it <b>opens</b> threads nobody has opened yet
        (earning 2 credits), <b>joins</b> other clubs' threads when you have a free credit (otherwise it waits and comes back
        when credits are earned), then bids up to your max. It never opens or joins after the cutoff, and it skips targets
        that would break your spend cap, max players to win, star cap (OooO not counted) or the 28-player squad limit.
        The plan only applies to the draft you choose and expires when it ends. Switching it off keeps bids already placed.
      </p>
      <div id="scoutAbPaused" class="scout-ab-status warn" hidden></div>
      <div class="scout-ab-row">
        <label for="scoutAbDraft">Player draft</label>
        <select id="scoutAbDraft" class="scout-board-select"></select>
        <span id="scoutAbAdminWrap" hidden>
          <label><input type="checkbox" id="scoutAbAdminPause" /> Admin: pause all plans</label>
        </span>
      </div>
      <div id="scoutAbPlanStatus" class="scout-ab-status" hidden></div>
      <div class="scout-ab-row">
        <label for="scoutAbSpendCap">Total spend cap (₿m)</label>
        <input type="number" id="scoutAbSpendCap" min="0" step="0.5" placeholder="No cap" />
        <label for="scoutAbMaxWins">Max players to win</label>
        <input type="number" id="scoutAbMaxWins" min="1" max="28" step="1" placeholder="No limit" />
        <label><input type="checkbox" id="scoutAbEnabled" checked /> Plan switched on</label>
      </div>
      <div class="scout-ab-row">
        <button type="button" class="button secondary" id="scoutAbSeedBtn"></button>
        <span class="meta" id="scoutAbCount"></span>
      </div>
      <div id="scoutAbTableWrap"></div>
      <div class="scout-ab-actions">
        <button type="button" class="button" id="scoutAbSaveBtn">Save plan</button>
        <button type="button" class="button secondary" id="scoutAbRefreshBtn">Refresh status</button>
        <button type="button" class="button secondary" id="scoutAbDeleteBtn" hidden>Delete plan</button>
        <span id="scoutAbMsg" class="scout-ab-msg" aria-live="polite"></span>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  return overlay;
}

/**
 * @param {object} opts
 * @param {import("@supabase/supabase-js").SupabaseClient} opts.supabase
 * @param {() => string|null} opts.getClubShort
 * @param {() => object[]} opts.getSeedRows  Active Targets in the current board view:
 *   { player_id, name, position, rating, market_value, contracted_team }
 * @param {() => string} opts.getBoardFilter  "all" or board number
 * @param {(boardNo: number) => string} opts.getBoardLabel
 */
export function wireAutoBidPlan({ supabase, getClubShort, getSeedRows, getBoardFilter, getBoardLabel }) {
  const btn = document.getElementById("scoutAutoBidBtn");
  if (!btn || btn.dataset.wired === "1") return;
  btn.dataset.wired = "1";

  injectStyles();
  const overlay = buildOverlay();
  const $ = (id) => document.getElementById(id);

  /** @type {{ options: object[], data: object|null, rows: object[], dirty: boolean, busy: boolean, timer: number|null }} */
  const st = { options: [], data: null, rows: [], dirty: false, busy: false, timer: null };

  function setMsg(text, tone = "") {
    const el = $("scoutAbMsg");
    if (!el) return;
    el.textContent = text || "";
    el.className = `scout-ab-msg ${tone}`;
  }

  function boardViewLabel() {
    const f = String(getBoardFilter?.() ?? "all");
    return f === "all" ? "all boards" : getBoardLabel?.(Number(f)) || `Board ${f}`;
  }

  function selectedOption() {
    const v = $("scoutAbDraft")?.value || "";
    return st.options.find((o) => String(o.start_at) === v) || null;
  }

  function seedRowToTarget(r, priority) {
    const mv = Number(r.market_value) || 0;
    return {
      player_id: String(r.player_id),
      name: r.name || String(r.player_id),
      position: r.position || "",
      rating: r.rating ?? null,
      market_value: mv,
      contracted_team: r.contracted_team || null,
      priority,
      max_amount: mv > 0 ? mv : null,
      included: true,
      allow_open: true,
      state: "pending",
      state_note: null,
      leader: null,
      high_bid: null,
    };
  }

  function renumber() {
    st.rows.forEach((r, i) => {
      r.priority = i + 1;
    });
  }

  function renderStatus() {
    const d = st.data;
    const paused = $("scoutAbPaused");
    if (paused) {
      paused.hidden = !d?.paused;
      paused.textContent = d?.paused
        ? "Auto-bid plans are paused by the admins right now — nothing will be bid until they're switched back on."
        : "";
    }
    const adminWrap = $("scoutAbAdminWrap");
    if (adminWrap) adminWrap.hidden = !d?.is_admin;
    const adminPause = $("scoutAbAdminPause");
    if (adminPause) adminPause.checked = !!d?.paused;

    const statusEl = $("scoutAbPlanStatus");
    const plan = d?.plan || null;
    const delBtn = $("scoutAbDeleteBtn");
    if (delBtn) delBtn.hidden = !plan || !["scheduled", "live"].includes(plan.status);
    if (!statusEl) return;
    if (!plan) {
      statusEl.hidden = false;
      statusEl.className = "scout-ab-status";
      statusEl.textContent = "No plan saved for this draft yet.";
      return;
    }
    const bits = [PLAN_STATUS_LABELS[plan.status] || plan.status];
    if (!plan.enabled) bits.push("switched off");
    if (plan.last_run_at) bits.push(`last checked ${fmtWhen(plan.last_run_at)}`);
    if (plan.last_error) bits.push(`last error: ${plan.last_error}`);
    statusEl.hidden = false;
    statusEl.className = `scout-ab-status${plan.last_error ? " bad" : !plan.enabled ? " warn" : ""}`;
    statusEl.textContent = bits.join(" · ");
  }

  function renderCaps() {
    const plan = st.data?.plan || null;
    const cap = $("scoutAbSpendCap");
    const wins = $("scoutAbMaxWins");
    const en = $("scoutAbEnabled");
    if (cap) cap.value = plan?.spend_cap ? toMillions(plan.spend_cap) : "";
    if (wins) wins.value = plan?.max_wins ? String(plan.max_wins) : "";
    if (en) en.checked = plan ? !!plan.enabled : true;
  }

  function readOnly() {
    const s = st.data?.plan?.status;
    return s === "finished" || s === "expired";
  }

  function renderTable() {
    const wrap = $("scoutAbTableWrap");
    const seedBtn = $("scoutAbSeedBtn");
    const count = $("scoutAbCount");
    if (seedBtn) {
      seedBtn.textContent = st.data?.plan
        ? `Add Active Targets from ${boardViewLabel()}`
        : `Load Active Targets from ${boardViewLabel()}`;
      seedBtn.disabled = readOnly();
    }
    const included = st.rows.filter((r) => r.included);
    const total = included.reduce((s, r) => s + (Number(r.max_amount) || 0), 0);
    if (count) {
      count.textContent = st.rows.length
        ? `${included.length} included · max bids total ${formatMoney(total)}`
        : "";
    }
    if (!wrap) return;
    if (!st.rows.length) {
      wrap.innerHTML =
        '<p class="meta">No targets in this plan. Mark players as Active Targets on a board view, then load them here.</p>';
      return;
    }
    const ro = readOnly();
    const live = !!st.data?.draft_live || st.data?.plan?.status === "live";
    const club = getClubShort?.() || "";
    wrap.innerHTML = `
      <table class="scout-ab-table">
        <thead><tr>
          <th>#</th><th>Player</th><th>Pos</th><th>Rtg</th><th>Opening (MV)</th>
          <th>Max bid (₿m)</th><th title="Allow the plan to open this thread if nobody has">May open</th>
          <th>Include</th><th>Status</th><th></th>
        </tr></thead>
        <tbody>
          ${st.rows
            .map((r, i) => {
              const mv = Number(r.market_value) || 0;
              const max = Number(r.max_amount) || 0;
              const below = mv > 0 && max > 0 && max < mv;
              const tone = STATE_TONE[r.state] || "muted";
              let note = r.state_note || "";
              if (live && r.high_bid != null) {
                const who = r.leader && club && r.leader === club ? "you" : r.leader || "—";
                note = `${note ? `${note} · ` : ""}high ${formatMoney(r.high_bid)} (${who})`;
              }
              return `
                <tr class="${r.included ? "" : "is-off"}" data-pid="${esc(r.player_id)}">
                  <td>${i + 1}</td>
                  <td>${esc(r.name)}</td>
                  <td>${esc(r.position || "")}</td>
                  <td>${esc(r.rating ?? "")}</td>
                  <td>${mv ? formatMoney(mv) : "—"}</td>
                  <td>
                    <input type="number" class="scout-ab-max" min="0" step="0.5" value="${esc(toMillions(max))}" ${ro ? "disabled" : ""} />
                    ${below ? '<span class="scout-ab-warn">Below opening price — can only join</span>' : ""}
                  </td>
                  <td><input type="checkbox" class="scout-ab-open" ${r.allow_open ? "checked" : ""} ${ro ? "disabled" : ""} /></td>
                  <td><input type="checkbox" class="scout-ab-inc" ${r.included ? "checked" : ""} ${ro ? "disabled" : ""} /></td>
                  <td>
                    <span class="scout-ab-pill ${tone}">${esc(STATE_LABELS[r.state] || r.state || "—")}</span>
                    ${note ? `<span class="scout-ab-note">${esc(note)}</span>` : ""}
                  </td>
                  <td style="white-space:nowrap;">
                    ${
                      ro
                        ? ""
                        : `<button type="button" class="button secondary scout-ab-mini" data-act="up" title="Higher priority" ${i === 0 ? "disabled" : ""}>↑</button>
                           <button type="button" class="button secondary scout-ab-mini" data-act="down" title="Lower priority" ${i === st.rows.length - 1 ? "disabled" : ""}>↓</button>
                           <button type="button" class="button secondary scout-ab-mini" data-act="remove" title="Remove from plan">✕</button>`
                    }
                  </td>
                </tr>`;
            })
            .join("")}
        </tbody>
      </table>`;
  }

  function renderAll() {
    renderStatus();
    renderCaps();
    renderTable();
    const ro = readOnly();
    ["scoutAbSpendCap", "scoutAbMaxWins", "scoutAbEnabled", "scoutAbSaveBtn"].forEach((id) => {
      const el = $(id);
      if (el) el.disabled = ro;
    });
  }

  function rowsFromData(data) {
    return (data?.targets || []).map((t) => ({
      player_id: String(t.player_id),
      name: t.name || String(t.player_id),
      position: t.position || "",
      rating: t.rating ?? null,
      market_value: Number(t.market_value) || 0,
      contracted_team: t.contracted_team || null,
      priority: t.priority,
      max_amount: Number(t.max_amount) || null,
      included: t.included !== false,
      allow_open: t.allow_open !== false,
      state: t.state || "pending",
      state_note: t.state_note || null,
      leader: t.leader || null,
      high_bid: t.high_bid != null ? Number(t.high_bid) : null,
    }));
  }

  async function loadPlan({ keepEdits = false } = {}) {
    const opt = selectedOption();
    if (!opt) {
      st.data = null;
      st.rows = [];
      renderAll();
      return;
    }
    const { data, error } = await supabase.rpc("player_draft_autobid_get", {
      p_draft_start: opt.start_at,
    });
    if (error) {
      setMsg(error.message || "Could not load the plan.", "bad");
      return;
    }
    st.data = data || null;
    if (!keepEdits || !st.dirty) {
      if (data?.plan) {
        st.rows = rowsFromData(data);
      } else {
        st.rows = (getSeedRows?.() || [])
          .filter((r) => !(r.contracted_team && r.contracted_team === getClubShort?.()))
          .map((r, i) => seedRowToTarget(r, i + 1));
      }
      st.dirty = false;
    } else {
      const byPid = new Map(rowsFromData(data).map((r) => [r.player_id, r]));
      st.rows.forEach((r) => {
        const live = byPid.get(r.player_id);
        if (live) {
          r.state = live.state;
          r.state_note = live.state_note;
          r.leader = live.leader;
          r.high_bid = live.high_bid;
        }
      });
    }
    renderAll();
  }

  async function loadOptions() {
    const sel = $("scoutAbDraft");
    const { data, error } = await supabase.rpc("player_draft_autobid_draft_options");
    if (error) {
      st.options = [];
      if (sel) sel.innerHTML = '<option value="">— unavailable —</option>';
      setMsg(
        /player_draft_autobid/.test(error.message || "")
          ? "Auto-bid plans are not set up on the server yet."
          : error.message || "Could not load player drafts.",
        "bad"
      );
      return false;
    }
    st.options = Array.isArray(data) ? data : [];
    if (!sel) return true;
    if (!st.options.length) {
      sel.innerHTML = '<option value="">No player draft scheduled yet</option>';
      return true;
    }
    const prev = sel.value;
    sel.innerHTML = st.options
      .map(
        (o) =>
          `<option value="${esc(o.start_at)}">${esc(o.label)}${o.has_plan ? " · plan saved" : ""}</option>`
      )
      .join("");
    if (prev && st.options.some((o) => String(o.start_at) === prev)) sel.value = prev;
    return true;
  }

  function collectPayload() {
    const capRaw = $("scoutAbSpendCap")?.value;
    const winsRaw = $("scoutAbMaxWins")?.value;
    const spendCap = capRaw ? fromMillions(capRaw) : null;
    const maxWins = winsRaw ? Math.trunc(Number(winsRaw)) : null;
    const f = String(getBoardFilter?.() ?? "all");
    const opt = selectedOption();
    return {
      p_draft_start: opt?.start_at || null,
      p_draft_label: opt?.label || null,
      p_source_board: f === "all" ? null : Number(f),
      p_spend_cap: spendCap,
      p_max_wins: Number.isFinite(maxWins) && maxWins > 0 ? maxWins : null,
      p_enabled: !!$("scoutAbEnabled")?.checked,
      p_targets: st.rows.map((r, i) => ({
        player_id: r.player_id,
        priority: i + 1,
        max_amount: r.max_amount,
        included: !!r.included,
        allow_open: !!r.allow_open,
      })),
    };
  }

  async function save() {
    if (st.busy) return;
    const payload = collectPayload();
    if (!payload.p_draft_start) {
      setMsg("Choose a player draft first.", "bad");
      return;
    }
    const missing = st.rows.find((r) => r.included && !(Number(r.max_amount) > 0));
    if (missing) {
      setMsg(`Set a max bid for ${missing.name}.`, "bad");
      return;
    }
    if (!st.rows.length) {
      setMsg("Add at least one target.", "bad");
      return;
    }
    st.busy = true;
    setMsg("Saving…");
    const { data, error } = await supabase.rpc("player_draft_autobid_save", payload);
    st.busy = false;
    if (error) {
      setMsg(error.message || "Could not save the plan.", "bad");
      return;
    }
    st.data = data || null;
    st.rows = rowsFromData(data);
    st.dirty = false;
    renderAll();
    await loadOptions();
    setMsg(
      payload.p_enabled ? "Plan saved — it will run while the draft is live." : "Plan saved (switched off).",
      "ok"
    );
  }

  async function removePlan() {
    const opt = selectedOption();
    if (!opt || !st.data?.plan) return;
    if (
      !window.confirm(
        "Delete this auto-bid plan? Bids already placed stay in place; the plan's max bids stop defending."
      )
    ) {
      return;
    }
    const { error } = await supabase.rpc("player_draft_autobid_delete", { p_draft_start: opt.start_at });
    if (error) {
      setMsg(error.message || "Could not delete the plan.", "bad");
      return;
    }
    st.dirty = false;
    await loadOptions();
    await loadPlan();
    setMsg("Plan deleted.", "ok");
  }

  function seedFromBoard() {
    const existing = new Set(st.rows.map((r) => r.player_id));
    const club = getClubShort?.() || "";
    let added = 0;
    for (const r of getSeedRows?.() || []) {
      const pid = String(r.player_id);
      if (existing.has(pid)) continue;
      if (r.contracted_team && club && r.contracted_team === club) continue;
      st.rows.push(seedRowToTarget(r, st.rows.length + 1));
      existing.add(pid);
      added += 1;
    }
    renumber();
    if (added) st.dirty = true;
    renderTable();
    setMsg(added ? `Added ${added} target(s) — remember to save.` : "No new Active Targets in this board view.");
  }

  function stopTimer() {
    if (st.timer) {
      window.clearInterval(st.timer);
      st.timer = null;
    }
  }

  function close() {
    overlay.hidden = true;
    stopTimer();
  }

  async function open() {
    if (!getClubShort?.()) {
      window.alert("You need a club to use auto-bid plans.");
      return;
    }
    overlay.hidden = false;
    setMsg("");
    const ok = await loadOptions();
    if (ok) await loadPlan();
    stopTimer();
    st.timer = window.setInterval(() => {
      if (overlay.hidden) return stopTimer();
      if (st.data?.plan?.status === "live" || st.data?.draft_live) {
        loadPlan({ keepEdits: true });
      }
    }, 60000);
  }

  btn.addEventListener("click", open);
  $("scoutAbClose")?.addEventListener("click", close);
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) close();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !overlay.hidden) close();
  });

  $("scoutAbDraft")?.addEventListener("change", () => {
    if (st.dirty && !window.confirm("Discard unsaved changes to this plan?")) return;
    st.dirty = false;
    loadPlan();
  });
  $("scoutAbSeedBtn")?.addEventListener("click", seedFromBoard);
  $("scoutAbSaveBtn")?.addEventListener("click", save);
  $("scoutAbDeleteBtn")?.addEventListener("click", removePlan);
  $("scoutAbRefreshBtn")?.addEventListener("click", () => loadPlan({ keepEdits: true }));
  ["scoutAbSpendCap", "scoutAbMaxWins", "scoutAbEnabled"].forEach((id) => {
    $(id)?.addEventListener("change", () => {
      st.dirty = true;
    });
  });

  $("scoutAbAdminPause")?.addEventListener("change", async (e) => {
    const paused = !!e.target.checked;
    const { error } = await supabase.rpc("admin_set_draft_autobid_paused", { p_paused: paused });
    if (error) {
      e.target.checked = !paused;
      setMsg(error.message || "Could not change the pause switch.", "bad");
      return;
    }
    if (st.data) st.data.paused = paused;
    renderStatus();
    setMsg(paused ? "All auto-bid plans paused." : "Auto-bid plans running again.", "ok");
  });

  $("scoutAbTableWrap")?.addEventListener("change", (e) => {
    const tr = e.target.closest("tr[data-pid]");
    if (!tr) return;
    const row = st.rows.find((r) => r.player_id === tr.dataset.pid);
    if (!row) return;
    if (e.target.classList.contains("scout-ab-max")) {
      row.max_amount = fromMillions(e.target.value);
    } else if (e.target.classList.contains("scout-ab-open")) {
      row.allow_open = !!e.target.checked;
    } else if (e.target.classList.contains("scout-ab-inc")) {
      row.included = !!e.target.checked;
    } else {
      return;
    }
    st.dirty = true;
    renderTable();
  });

  $("scoutAbTableWrap")?.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-act]");
    if (!b) return;
    const tr = b.closest("tr[data-pid]");
    const idx = st.rows.findIndex((r) => r.player_id === tr?.dataset.pid);
    if (idx < 0) return;
    const act = b.dataset.act;
    if (act === "up" && idx > 0) {
      [st.rows[idx - 1], st.rows[idx]] = [st.rows[idx], st.rows[idx - 1]];
    } else if (act === "down" && idx < st.rows.length - 1) {
      [st.rows[idx + 1], st.rows[idx]] = [st.rows[idx], st.rows[idx + 1]];
    } else if (act === "remove") {
      st.rows.splice(idx, 1);
    } else {
      return;
    }
    renumber();
    st.dirty = true;
    renderTable();
  });
}
