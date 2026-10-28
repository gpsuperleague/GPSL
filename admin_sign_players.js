import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";
import {
  MIN_GOALKEEPERS,
  MIN_HOME_GROWN,
  MIN_SQUAD_SIZE,
  MIN_UNDER_21,
  SQUAD_SIZE,
} from "./squad_rules.js";

primeAdminPageChrome();

const POSITION_GROUPS = {
  Goalkeepers: ["GK"],
  Defenders: ["LB", "CB", "RB"],
  Midfielders: ["DMF", "LMF", "CMF", "RMF", "AMF"],
  Attackers: ["LW", "LWF", "SS", "RW", "RWF", "CF"],
};

const DRAFT_KEY = "gpsl_admin_sign_fa_draft_v1";

/** @type {Map<string, object>} */
const basket = new Map();
/** @type {object|null} */
let lastPreview = null;
/** @type {object|null} */
let clubContext = null;
/** Skip auto home-nation when restoring a saved draft */
let restoreNationOverride = null;
/** Prevent club-change handler from double-loading during bootstrap */
let bootstrapping = false;
/** Last club the basket belonged to (select value is already new on change) */
let activeClub = "";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  wireUi();
  await loadClubs();
  await restoreDraftOnLoad();
});

function readDraftStore() {
  try {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return { version: 1, lastClub: "", clubs: {} };
    const parsed = JSON.parse(raw);
    return {
      version: 1,
      lastClub: String(parsed?.lastClub || ""),
      clubs: parsed?.clubs && typeof parsed.clubs === "object" ? parsed.clubs : {},
    };
  } catch {
    return { version: 1, lastClub: "", clubs: {} };
  }
}

function writeDraftStore(store) {
  try {
    localStorage.setItem(DRAFT_KEY, JSON.stringify(store));
  } catch {
    /* ignore quota / private mode */
  }
}

function persistDraft(forClub) {
  const club = forClub || document.getElementById("clubSelect")?.value || "";
  if (!club) return;
  const store = readDraftStore();
  const players = [...basket.values()];
  const nation = document.getElementById("nationSelect")?.value || "";
  const searchQ = document.getElementById("searchQ")?.value || "";

  if (!players.length) {
    delete store.clubs[club];
  } else {
    store.clubs[club] = {
      players,
      nation,
      searchQ,
      updatedAt: new Date().toISOString(),
    };
  }
  store.lastClub = club;
  writeDraftStore(store);
}

function clearDraftForClub(club) {
  if (!club) return;
  const store = readDraftStore();
  delete store.clubs[club];
  if (store.lastClub === club) store.lastClub = "";
  writeDraftStore(store);
}

function applyBasketFromDraft(club) {
  basket.clear();
  const draft = readDraftStore().clubs?.[club];
  if (!draft || !Array.isArray(draft.players)) return null;
  for (const p of draft.players) {
    const id = String(p?.player_id || "");
    if (!id) continue;
    basket.set(id, normalizeSearchRow(p));
  }
  return draft;
}

async function restoreDraftOnLoad() {
  const store = readDraftStore();
  const club = store.lastClub;
  const sel = document.getElementById("clubSelect");
  if (!club || !sel) return;
  if (![...sel.options].some((o) => o.value === club)) return;

  bootstrapping = true;
  const draft = store.clubs?.[club] || null;
  restoreNationOverride =
    draft && Object.prototype.hasOwnProperty.call(draft, "nation")
      ? draft.nation
      : null;
  if (draft?.searchQ) {
    const qEl = document.getElementById("searchQ");
    if (qEl) qEl.value = draft.searchQ;
  }
  sel.value = club;
  activeClub = club;
  applyBasketFromDraft(club);
  await loadClubContext({ fromRestore: true });
  renderBasket();
  renderBuildPanel();
  bootstrapping = false;
  restoreNationOverride = null;

  if (basket.size) {
    setStatus(
      "pageStatus",
      `Restored draft for ${club}: ${basket.size} player(s) in basket.`
    );
  }
}

function wireUi() {
  document.getElementById("searchBtn")?.addEventListener("click", runSearch);
  document.getElementById("searchQ")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      runSearch();
    }
  });
  document.getElementById("searchQ")?.addEventListener("change", persistDraft);
  document.getElementById("nationSelect")?.addEventListener("change", () => {
    persistDraft();
    const q = document.getElementById("searchQ")?.value?.trim() || "";
    const nation = document.getElementById("nationSelect")?.value || "";
    if (nation || q.length >= 2) runSearch();
  });
  document.getElementById("previewBtn")?.addEventListener("click", () => runSign(true));
  document.getElementById("signBtn")?.addEventListener("click", () => runSign(false));
  document.getElementById("clearBtn")?.addEventListener("click", () => {
    const club = document.getElementById("clubSelect")?.value || "";
    basket.clear();
    lastPreview = null;
    clearDraftForClub(club);
    renderBasket();
    renderBuildPanel();
    document.getElementById("signBtn").disabled = true;
    document.getElementById("resultBox").textContent = "";
    setStatus("pageStatus", "Basket cleared.");
  });
  document.getElementById("clubSelect")?.addEventListener("change", async () => {
    if (bootstrapping) return;
    const next = document.getElementById("clubSelect")?.value || "";
    if (activeClub) persistDraft(activeClub);
    lastPreview = null;
    document.getElementById("signBtn").disabled = true;
    const draft = next ? applyBasketFromDraft(next) : (basket.clear(), null);
    activeClub = next;
    restoreNationOverride =
      draft && Object.prototype.hasOwnProperty.call(draft, "nation")
        ? draft.nation
        : null;
    if (draft?.searchQ != null) {
      const qEl = document.getElementById("searchQ");
      if (qEl) qEl.value = draft.searchQ;
    } else if (!draft) {
      const qEl = document.getElementById("searchQ");
      if (qEl) qEl.value = "";
    }
    await loadClubContext({ fromRestore: !!draft });
    restoreNationOverride = null;
    renderBasket();
    renderBuildPanel();
    if (next) persistDraft(next);
  });
}

async function loadClubs() {
  const sel = document.getElementById("clubSelect");
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error || !data?.length) {
    sel.innerHTML = '<option value="">Failed to load clubs</option>';
    return;
  }

  sel.innerHTML =
    '<option value="">Select club…</option>' +
    data
      .map(
        (c) =>
          `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(c.Club || c.ShortName)} (${escapeHtml(c.ShortName)})</option>`
      )
      .join("");
}

async function loadClubContext(opts = {}) {
  const club = document.getElementById("clubSelect")?.value || "";
  clubContext = null;
  renderManager(null);
  renderBuildPanel();

  if (!club) {
    fillNationSelect([]);
    document.getElementById("squadBuild").innerHTML =
      `<p class="empty">Select a club to load the current squad.</p>`;
    return;
  }

  document.getElementById("squadBuild").innerHTML = `<p class="empty">Loading squad…</p>`;
  const { data, error } = await supabase.rpc("admin_sign_fa_club_build_context", {
    p_club_short_name: club,
  });

  if (error || !data?.ok) {
    document.getElementById("squadBuild").innerHTML = `<p class="empty">${escapeHtml(
      error?.message || data?.reason || "Failed to load club context"
    )}</p>`;
    return;
  }

  clubContext = data;
  activeClub = club;
  const preferred =
    restoreNationOverride != null ? restoreNationOverride : data.club_nation;
  fillNationSelect(Array.isArray(data.fa_nations) ? data.fa_nations : [], preferred, {
    forcePreferred: restoreNationOverride != null || !!opts.fromRestore,
  });
  // Re-flag basket rows now that club HG/star context is known
  for (const [id, row] of basket) basket.set(id, normalizeSearchRow(row));
  renderManager(data.manager);
  renderBuildPanel();
  persistDraft(club);
  // Browse filtered FAs (home nation or restored nation)
  if (document.getElementById("nationSelect")?.value) {
    runSearch();
  }
}

function nationKeyLoose(s) {
  return String(s || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "");
}

function fillNationSelect(nations, preferredNation, opts = {}) {
  const sel = document.getElementById("nationSelect");
  if (!sel) return;

  const list = [...(nations || []).map((n) => String(n || "")).filter(Boolean)];
  const clubHome = String(clubContext?.club_nation || "").trim();
  const preferred = String(
    preferredNation != null ? preferredNation : clubHome
  ).trim();
  if (clubHome && !list.some((n) => nationKeyLoose(n) === nationKeyLoose(clubHome))) {
    list.unshift(clubHome);
  }
  if (
    preferred &&
    !list.some((n) => nationKeyLoose(n) === nationKeyLoose(preferred))
  ) {
    list.unshift(preferred);
  }
  list.sort((a, b) => a.localeCompare(b));

  const homeKey = nationKeyLoose(clubHome);
  const preferKey = nationKeyLoose(preferred);
  const matchedPreferred = preferKey
    ? list.find((n) => nationKeyLoose(n) === preferKey)
    : "";

  const optsHtml = ['<option value="">Any nation</option>'].concat(
    list.map((v) => {
      const isHome = homeKey && nationKeyLoose(v) === homeKey;
      const label = isHome ? `${v} (home · HG)` : v;
      return `<option value="${escapeHtml(v)}">${escapeHtml(label)}</option>`;
    })
  );
  sel.innerHTML = optsHtml.join("");

  if (preferred === "" && opts.forcePreferred) {
    sel.value = "";
  } else {
    sel.value = matchedPreferred || (homeKey ? list.find((n) => nationKeyLoose(n) === homeKey) || "" : "");
  }
}

function renderManager(mgr) {
  const box = document.getElementById("managerBox");
  if (!box) return;
  if (!mgr) {
    box.hidden = true;
    box.innerHTML = "";
    return;
  }
  box.hidden = false;
  box.innerHTML = `Manager: <b>${escapeHtml(mgr.manager_name || "—")}</b>
    · OVR <b>${mgr.manager_rating ?? "—"}</b>
    · MV <b>${escapeHtml(formatMoney(Number(mgr.manager_market_value) || 0))}</b>`;
}

function projectedPlayers() {
  const owned = Array.isArray(clubContext?.players) ? clubContext.players : [];
  const ownedIds = new Set(owned.map((p) => String(p.player_id)));
  const incoming = [...basket.values()]
    .filter((p) => !ownedIds.has(String(p.player_id)))
    .map((p) => ({
      player_id: String(p.player_id),
      player_name: p.player_name,
      position: p.position,
      nation: p.nation,
      rating: p.rating,
      age: p.age,
      market_value: Number(p.market_value) || 0,
      is_home_grown: !!p.is_home_grown,
      is_u21: !!p.is_u21,
      is_star: !!p.is_star,
      is_gk: !!p.is_gk || String(p.position || "").toUpperCase() === "GK",
      from_basket: true,
    }));
  return [...owned.map((p) => ({ ...p, from_basket: false })), ...incoming];
}

function countFlags(players) {
  return {
    total: players.length,
    stars: players.filter((p) => p.is_star).length,
    u21: players.filter((p) => p.is_u21).length,
    hg: players.filter((p) => p.is_home_grown).length,
    gk: players.filter((p) => p.is_gk || String(p.position || "").toUpperCase() === "GK").length,
  };
}

function financeProjection() {
  const balance = Number(clubContext?.balance) || 0;
  const taxPct = Number(clubContext?.income_tax_pct) || 0;
  let fees = 0;
  for (const p of basket.values()) fees += Number(p.market_value) || 0;
  const tax = fees * (taxPct / 100);
  const totalCost = fees + tax;
  return {
    balance,
    taxPct,
    fees,
    tax,
    totalCost,
    after: balance - totalCost,
  };
}

function renderLimits(counts) {
  const box = document.getElementById("limitsBox");
  if (!box) return;
  const starCap = Number(clubContext?.star_cap) || 2;
  const minHg = Number(clubContext?.min_home_grown) || MIN_HOME_GROWN;
  const minU21 = Number(clubContext?.min_under_21) || MIN_UNDER_21;
  const minGk = Number(clubContext?.min_goalkeepers) || MIN_GOALKEEPERS;
  const minSquad = Number(clubContext?.min_squad_size) || MIN_SQUAD_SIZE;
  const maxSquad = Number(clubContext?.max_squad_size) || SQUAD_SIZE;

  const squadCls =
    counts.total > maxSquad ? "bad" : counts.total >= minSquad ? "ok" : "warn";
  const starCls = counts.stars > starCap ? "bad" : counts.stars === starCap ? "warn" : "ok";
  const u21Cls = counts.u21 >= minU21 ? "ok" : "bad";
  const hgCls = counts.hg >= minHg ? "ok" : "bad";
  const gkCls = counts.gk >= minGk ? "ok" : "bad";

  box.innerHTML = `
    <div class="stat ${squadCls}">
      <div class="lbl">Squad</div>
      <div class="val">${counts.total}</div>
      <div class="lim">min ${minSquad} · max ${maxSquad}</div>
    </div>
    <div class="stat ${starCls}">
      <div class="lbl">Stars</div>
      <div class="val">${counts.stars}</div>
      <div class="lim">cap ${starCap} (≥${clubContext?.star_min_rating ?? 79})</div>
    </div>
    <div class="stat ${u21Cls}">
      <div class="lbl">U21</div>
      <div class="val">${counts.u21}</div>
      <div class="lim">min ${minU21}</div>
    </div>
    <div class="stat ${hgCls}">
      <div class="lbl">Home grown</div>
      <div class="val">${counts.hg}</div>
      <div class="lim">min ${minHg}${clubContext?.club_nation ? ` · ${escapeHtml(clubContext.club_nation)}` : ""}</div>
    </div>
    <div class="stat ${gkCls}">
      <div class="lbl">GK</div>
      <div class="val">${counts.gk}</div>
      <div class="lim">min ${minGk}</div>
    </div>`;
}

function renderFinance() {
  const box = document.getElementById("financeBox");
  if (!box) return;
  if (!clubContext) {
    box.hidden = true;
    return;
  }
  const f = financeProjection();
  const afterCls = f.after < 0 ? "neg" : "pos";
  box.hidden = false;
  box.innerHTML = `
    <div class="finance-row"><span>Balance</span><b>${escapeHtml(formatMoney(f.balance))}</b></div>
    <div class="finance-row"><span>Basket fees</span><b>${escapeHtml(formatMoney(f.fees))}</b></div>
    <div class="finance-row"><span>Est. income tax (${f.taxPct}%)</span><b>${escapeHtml(formatMoney(f.tax))}</b></div>
    <div class="finance-row"><span>Est. total cost</span><b>${escapeHtml(formatMoney(f.totalCost))}</b></div>
    <div class="finance-row ${afterCls}"><span>Balance after</span><b>${escapeHtml(formatMoney(f.after))}</b></div>
    <div class="hint" style="margin-top:6px;">Updates as you add/remove players. Tax confirmed on Preview.</div>`;
}

function playerTags(p) {
  const tags = [];
  if (p.from_basket) tags.push('<span class="tag new">new</span>');
  if (p.is_star) tags.push('<span class="tag star">★</span>');
  if (p.is_u21) tags.push('<span class="tag u21">U21</span>');
  if (p.is_home_grown) tags.push('<span class="tag hg">HG</span>');
  return tags.join("");
}

function renderSquadList(players) {
  const box = document.getElementById("squadBuild");
  if (!box) return;
  if (!clubContext) {
    box.innerHTML = `<p class="empty">Select a club to load the current squad.</p>`;
    return;
  }
  if (!players.length) {
    box.innerHTML = `<p class="empty">No players yet — add free agents to the basket.</p>`;
    return;
  }

  const used = new Set();
  const sections = [];

  for (const [groupName, positions] of Object.entries(POSITION_GROUPS)) {
    const groupPlayers = players
      .filter((p) => positions.includes(String(p.position || "").toUpperCase()))
      .sort((a, b) => (Number(b.market_value) || 0) - (Number(a.market_value) || 0));
    groupPlayers.forEach((p) => used.add(String(p.player_id)));
    if (!groupPlayers.length) continue;
    sections.push(renderSquadSection(groupName, groupPlayers));
  }

  const other = players
    .filter((p) => !used.has(String(p.player_id)))
    .sort((a, b) => (Number(b.market_value) || 0) - (Number(a.market_value) || 0));
  if (other.length) sections.push(renderSquadSection("Other", other));

  box.innerHTML = sections.join("") || `<p class="empty">No players.</p>`;
}

function renderSquadSection(title, rows) {
  return `<div class="squad-sec">
    <h3 class="squad-sec-title">${escapeHtml(title)} (${rows.length})</h3>
    <table class="sign-table">
      <tbody>
        ${rows
          .map(
            (p) => `<tr>
              <td>${escapeHtml(p.player_name || "—")}${playerTags(p)}
                <div class="hint">${escapeHtml(p.position || "—")} · ${escapeHtml(p.nation || "—")}${
                  p.age != null ? ` · ${escapeHtml(p.age)}` : ""
                }</div>
              </td>
              <td class="num">${p.rating ?? "—"}</td>
              <td class="num">${escapeHtml(formatMoney(Number(p.market_value) || 0))}</td>
            </tr>`
          )
          .join("")}
      </tbody>
    </table>
  </div>`;
}

function renderBuildPanel() {
  const players = projectedPlayers();
  renderLimits(countFlags(players));
  renderFinance();
  renderSquadList(players);
}

async function runSearch() {
  const q = document.getElementById("searchQ")?.value?.trim() || "";
  const nation = document.getElementById("nationSelect")?.value || "";
  const club = document.getElementById("clubSelect")?.value || "";
  const box = document.getElementById("searchResults");

  if (q.length < 2 && !nation) {
    box.innerHTML = `<p class="empty">Type at least 2 characters, or pick a nation.</p>`;
    return;
  }
  if (!club) {
    box.innerHTML = `<p class="empty">Pick a destination club first (needed for HG flags).</p>`;
    return;
  }

  box.innerHTML = `<p class="empty">Searching…</p>`;
  const { data, error } = await supabase.rpc("admin_search_free_agents_for_sign", {
    p_query: q,
    p_limit: 50,
    p_nation: nation || null,
    p_club_short_name: club,
  });
  if (error) {
    box.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    box.innerHTML = `<p class="empty">No free agents matched.</p>`;
    return;
  }
  box.innerHTML = `
    <table class="sign-table">
      <thead><tr>
        <th></th><th>Player</th><th>Pos</th><th>Nation</th><th class="num">Age</th><th class="num">OVR</th><th class="num">MV</th>
      </tr></thead>
      <tbody>
        ${rows
          .map((r) => {
            const id = String(r.player_id || "");
            const inBasket = basket.has(id);
            return `<tr>
              <td><button type="button" class="button add-btn" data-id="${escapeHtml(id)}" ${
                inBasket ? "disabled" : ""
              }>${inBasket ? "Added" : "Add"}</button></td>
              <td>${escapeHtml(r.player_name)}${playerTags({
                ...r,
                from_basket: false,
              })} <span class="hint">${escapeHtml(id)}</span></td>
              <td>${escapeHtml(r.position || "—")}</td>
              <td>${escapeHtml(r.nation || "—")}</td>
              <td class="num">${r.age ?? "—"}</td>
              <td class="num">${r.rating ?? "—"}</td>
              <td class="num">${escapeHtml(formatMoney(Number(r.market_value) || 0))}</td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  box.querySelectorAll(".add-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-id");
      const row = rows.find((r) => String(r.player_id) === id);
      if (!row) return;
      basket.set(id, normalizeSearchRow(row));
      lastPreview = null;
      document.getElementById("signBtn").disabled = true;
      btn.disabled = true;
      btn.textContent = "Added";
      renderBasket();
      renderBuildPanel();
      persistDraft();
    });
  });
}

function renderBasket() {
  const box = document.getElementById("basketBox");
  const rows = [...basket.values()];
  if (!rows.length) {
    box.innerHTML = `<p class="empty">No players selected yet.</p>`;
    return;
  }

  box.innerHTML = `
    <table class="sign-table">
      <thead><tr>
        <th>Player</th><th>Pos</th><th class="num">OVR</th><th class="num">MV</th><th></th>
      </tr></thead>
      <tbody>
        ${rows
          .map((r) => {
            const mv = Number(r.market_value) || 0;
            const id = String(r.player_id || "");
            return `<tr>
              <td>${escapeHtml(r.player_name)}${playerTags({
                ...r,
                from_basket: true,
              })}</td>
              <td>${escapeHtml(r.position || "—")}</td>
              <td class="num">${r.rating ?? "—"}</td>
              <td class="num">${escapeHtml(formatMoney(mv))}</td>
              <td><button type="button" class="button rm-btn" data-id="${escapeHtml(id)}">Remove</button></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  box.querySelectorAll(".rm-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      basket.delete(btn.getAttribute("data-id"));
      lastPreview = null;
      document.getElementById("signBtn").disabled = true;
      renderBasket();
      renderBuildPanel();
      persistDraft();
    });
  });
}

/** Apply signs in small RPCs — full-basket ledger path was timing out. */
const SIGN_BATCH_SIZE = 5;

function chunkIds(ids, size) {
  const out = [];
  for (let i = 0; i < ids.length; i += size) out.push(ids.slice(i, i + size));
  return out;
}

function formatSignResultLines(label, data) {
  const lines = [
    label,
    `Club ${data.club} · tax ${data.income_tax_pct}%`,
    `Balance before ${formatMoney(Number(data.balance_before) || 0)} · squad ${data.squad_before}`,
    `Would sign / signed: ${data.signed_count} · skipped: ${data.skipped_count}`,
    `Fees ${formatMoney(Number(data.fees_total) || 0)} + est. tax ${formatMoney(
      Number(data.est_income_tax_total) || 0
    )} = ${formatMoney(Number(data.est_total_cost) || 0)}`,
  ];
  if (Array.isArray(data.signed) && data.signed.length) {
    lines.push("", "Signed:");
    for (const s of data.signed) {
      lines.push(
        `  ${s.player_name} (${s.player_id}) ${s.position || ""} ${s.rating ?? ""} · ${formatMoney(
          Number(s.market_value) || 0
        )}`
      );
    }
  }
  if (Array.isArray(data.skipped) && data.skipped.length) {
    lines.push("", "Skipped:");
    for (const s of data.skipped) {
      lines.push(`  ${s.player_name || s.player_id}: ${s.reason}${s.detail ? " — " + s.detail : ""}`);
    }
  }
  return lines;
}

function mergeSignBatches(parts) {
  if (!parts.length) return null;
  const first = parts[0];
  const signed = [];
  const skipped = [];
  let fees = 0;
  let tax = 0;
  for (const p of parts) {
    if (Array.isArray(p.signed)) signed.push(...p.signed);
    if (Array.isArray(p.skipped)) skipped.push(...p.skipped);
    fees += Number(p.fees_total) || 0;
    tax += Number(p.est_income_tax_total) || 0;
  }
  return {
    ok: parts.every((p) => p?.ok),
    dry_run: first.dry_run,
    club: first.club,
    income_tax_pct: first.income_tax_pct,
    balance_before: first.balance_before,
    squad_before: first.squad_before,
    signed_count: signed.length,
    skipped_count: skipped.length,
    fees_total: fees,
    est_income_tax_total: tax,
    est_total_cost: fees + tax,
    signed,
    skipped,
  };
}

async function runSign(dryRun) {
  const club = document.getElementById("clubSelect")?.value || "";
  const ids = [...basket.keys()];
  const out = document.getElementById("resultBox");
  if (!club) {
    setStatus("pageStatus", "Pick a club first.", true);
    return;
  }
  if (!ids.length) {
    setStatus("pageStatus", "Add at least one free agent.", true);
    return;
  }
  if (!dryRun && !lastPreview?.ok) {
    setStatus("pageStatus", "Run Preview first.", true);
    return;
  }

  out.textContent = "";

  // Preview: one call (read-only, fast). Apply: batches of SIGN_BATCH_SIZE.
  const batches = dryRun ? [ids] : chunkIds(ids, SIGN_BATCH_SIZE);
  const parts = [];

  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    setStatus(
      "pageStatus",
      dryRun
        ? "Previewing…"
        : `Signing batch ${i + 1}/${batches.length} (${batch.length} player(s))…`
    );

    const { data, error } = await supabase.rpc("admin_sign_free_agents_at_mv", {
      p_club_short_name: club,
      p_player_ids: batch,
      p_dry_run: dryRun,
    });

    if (error) {
      setStatus("pageStatus", error.message, true);
      out.textContent =
        (parts.length
          ? formatSignResultLines(
              `PARTIAL (${parts.length} batch(es) before error)`,
              mergeSignBatches(parts)
            ).join("\n") + "\n\n"
          : "") + `ERROR: ${error.message}`;
      if (!dryRun && parts.length) {
        for (const p of parts) {
          for (const s of p.signed || []) basket.delete(String(s.player_id));
        }
        persistDraft();
        renderBasket();
        renderBuildPanel();
        await loadClubContext({ fromRestore: true });
      }
      return;
    }

    if (!data?.ok) {
      setStatus(
        "pageStatus",
        data?.detail || data?.reason || "Sign failed",
        true
      );
      out.textContent = JSON.stringify(data, null, 2);
      return;
    }

    parts.push(data);

    if (!dryRun) {
      for (const s of data.signed || []) basket.delete(String(s.player_id));
      persistDraft();
      renderBasket();
      renderBuildPanel();
    }
  }

  const data = mergeSignBatches(parts);
  lastPreview = dryRun ? data : null;
  document.getElementById("signBtn").disabled = !(
    dryRun &&
    data?.ok &&
    Number(data.signed_count) > 0
  );

  out.textContent = formatSignResultLines(
    dryRun ? "PREVIEW" : `SIGNED (${batches.length} batch(es))`,
    data
  ).join("\n");

  if (dryRun) {
    setStatus(
      "pageStatus",
      `Preview ready — ${data.signed_count} to sign. Click Sign to apply.`
    );
    return;
  }

  if (!basket.size) clearDraftForClub(club);
  else persistDraft();
  document.getElementById("signBtn").disabled = true;
  await loadClubContext({ fromRestore: true });
  setStatus(
    "pageStatus",
    basket.size
      ? `Signed ${data.signed_count}. ${basket.size} still in draft basket.`
      : `Done — signed ${data.signed_count}.`
  );
}

function normalizeSearchRow(r) {
  const starMin = Number(clubContext?.star_min_rating) || 79;
  const ratingNum = Number(String(r.rating ?? "").replace(/[^0-9]/g, "")) || 0;
  const ageNum = r.age != null && String(r.age).trim() !== "" ? Number(r.age) : null;
  const nationKey = String(clubContext?.club_nation_key || "").toLowerCase();
  const playerNation = String(r.nation || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "");
  const isHg =
    r.is_home_grown != null
      ? !!r.is_home_grown
      : !!nationKey && playerNation === nationKey;
  return {
    ...r,
    is_home_grown: isHg,
    is_u21: r.is_u21 != null ? !!r.is_u21 : ageNum != null && ageNum <= 21,
    is_star: r.is_star != null ? !!r.is_star : ratingNum >= starMin,
    is_gk:
      r.is_gk != null
        ? !!r.is_gk
        : String(r.position || "").toUpperCase() === "GK",
  };
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
