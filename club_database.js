import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";
import {
  discordChatLinkHtml,
  wireDiscordChatLinks,
} from "./discord_open.js?v=20260921-app-first";

const COLUMNS = [
  { key: "club_name", label: "Club", sort: "club_name" },
  { key: "stadium_name", label: "Stadium", sort: "stadium_name" },
  { key: "nation", label: "Nation", sort: "nation" },
  { key: "stadium_capacity", label: "Capacity", sort: "stadium_capacity" },
  { key: "stadium_max_capacity", label: "Max capacity", sort: "stadium_max_capacity" },
  { key: "stadium_expansion_potential", label: "Expansion headroom", sort: "stadium_expansion_potential" },
  { key: "club_expectation_label", label: "Expectation", sort: "club_expectation" },
  { key: "club_market_value", label: "Squad MV", sort: "club_market_value" },
  { key: "stadium_value", label: "Stadium value", sort: "stadium_value" },
  { key: "stadium_maintenance_cost", label: "Stadium maintenance", sort: "stadium_maintenance_cost" },
  { key: "gate_money_full", label: "Gate 100%", sort: "gate_money_full" },
  { key: "gate_money_80", label: "Gate 80%", sort: "gate_money_80" },
  { key: "owner_tag", label: "Owner", sort: "owner_tag" },
  { key: "interest", label: "Interest", sort: null },
  { key: "prestige_rank", label: "Prestige", sort: "prestige_rank" },
];

let allRows = [];
let sortKey = "prestige_rank";
let sortDir = "asc";
let page = 1;
let pageSize = 100;
/** @type {any} */
let interestState = null;
/** @type {any} */
let interestModalClub = null;

function setStatus(msg) {
  const el = document.getElementById("statusNote");
  if (el) el.textContent = msg || "";
}

function setError(msg) {
  const el = document.getElementById("cdbError");
  if (el) el.textContent = msg || "";
}

function moneyCell(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `<span class="money">${formatMoney(v)}</span>`;
}

function isVacant(row) {
  return row?.owner_id == null && String(row?.club_short_name || "").toUpperCase() !== "FOREIGN";
}

function interestsByClubMap() {
  const map = new Map();
  for (const row of interestState?.interests || []) {
    map.set(row.club_short_name, row);
  }
  return map;
}

function myMarkFor(clubShortName) {
  const interest = interestState?.mine_interest;
  const backup = interestState?.mine_backup;
  if (interest?.club_short_name === clubShortName) return interest;
  if (backup?.club_short_name === clubShortName) return backup;
  return null;
}

function ownersTooltip(owners, label) {
  if (!owners?.length) return `${label}: none`;
  return (
    `${label}:\n` +
    owners
      .map((o) => {
        const tag = o.owner_tag || "—";
        return o.note ? `• ${tag} — ${o.note}` : `• ${tag}`;
      })
      .join("\n")
  );
}

function renderInterestBanner() {
  const el = document.getElementById("interestBanner");
  if (!el) return;

  const url = interestState?.discord_chat_url || null;
  const frozen = Boolean(interestState?.frozen);
  const canMark = Boolean(interestState?.can_mark);
  const canView = Boolean(interestState?.can_view);
  const mineI = interestState?.mine_interest;
  const mineB = interestState?.mine_backup;

  const parts = [];
  parts.push(
    `<b>Club interest</b> — waiting-list / invited owners mark <b>1 interest</b> and <b>1 backup</b> on any club. Hover ★ / ☆ to see who.`
  );
  if (url) {
    parts.push(
      ` ${discordChatLinkHtml(url)} to discuss with others.`
    );
  } else {
    parts.push(
      ` <span class="discord-missing">Discord chat link not set yet</span> (admin: Transfer management → Club auction → Discord auction chat URL).`
    );
  }
  if (frozen) {
    parts.push(' <span class="frozen">Marks are frozen while bidding is open.</span>');
  } else if (canMark) {
    const iLabel = mineI ? escapeHtml(mineI.club_name || mineI.club_short_name) : "none";
    const bLabel = mineB ? escapeHtml(mineB.club_name || mineB.club_short_name) : "none";
    parts.push(` Your interest: <b>${iLabel}</b> · backup: <b>${bLabel}</b>.`);
  } else if (canView) {
    parts.push(" You can view marks; set your owner tag on Owner details to mark clubs.");
  } else {
    parts.push(
      ' Set your owner tag on <a href="awaiting_club.html">Owner details</a> if you are on the waiting list.'
    );
  }

  el.innerHTML = parts.join("");
  el.style.display = "block";
}

async function loadInterestState() {
  const { data, error } = await supabase.rpc("club_auction_interest_list");
  if (error) {
    console.warn("club_database: interest list failed", error);
    interestState = {
      ok: false,
      frozen: false,
      can_mark: false,
      can_view: false,
      max_interests: 1,
      max_backups: 1,
      my_interest_count: 0,
      my_backup_count: 0,
      discord_chat_url: null,
      interests: [],
      mine: [],
      mine_interest: null,
      mine_backup: null,
    };
  } else {
    interestState = data;
  }
  renderInterestBanner();
}

function interestCellHtml(row) {
  const clubShort = row.club_short_name || "";
  if (String(clubShort).toUpperCase() === "FOREIGN") {
    return `<td class="interest-cell"><span style="color:#555;">—</span></td>`;
  }

  const group = interestsByClubMap().get(clubShort);
  const canView = Boolean(interestState?.can_view);
  const canMark = Boolean(interestState?.can_mark);
  const frozen = Boolean(interestState?.frozen);
  const mine = myMarkFor(clubShort);

  const iCount = Number(group?.interest_count || 0);
  const bCount = Number(group?.backup_count || 0);
  const iOwners = group?.interest_owners || [];
  const bOwners = group?.backup_owners || [];

  let countsHtml = "";
  if (canView) {
    const iTitle = escapeHtml(ownersTooltip(iOwners, "Interest"));
    const bTitle = escapeHtml(ownersTooltip(bOwners, "Backup"));
    countsHtml = `<div class="interest-counts">
      <span class="interest-count" title="${iTitle}">★ ${iCount}</span>
      <span class="backup-count" title="${bTitle}">☆ ${bCount}</span>
    </div>`;
  } else {
    countsHtml = `<div class="interest-counts" style="color:#666;">—</div>`;
  }

  let btnHtml = "";
  if (canMark || mine) {
    const label = mine
      ? frozen
        ? mine.mark_kind === "backup"
          ? "Your backup"
          : "Your interest"
        : "Edit mark"
      : "Mark";
    const cls = "interest-btn" + (mine ? " is-marked" : "");
    const disabled = !canMark && !mine ? " disabled" : "";
    btnHtml = `<button type="button" class="${cls}" data-interest-club="${escapeHtml(
      clubShort
    )}"${disabled}>${label}</button>`;
  }

  return `<td class="interest-cell" data-club="${escapeHtml(clubShort)}">
    ${countsHtml}
    ${btnHtml}
  </td>`;
}

function buildHead() {
  const head = document.getElementById("tableHead");
  if (!head) return;
  head.innerHTML =
    "<tr>" +
    COLUMNS.map((c) => {
      if (!c.sort) return `<th>${c.label}</th>`;
      const cls =
        sortKey === c.sort ? (sortDir === "asc" ? "sort-asc" : "sort-desc") : "";
      return `<th class="${cls}" data-sort="${c.sort}">${c.label}</th>`;
    }).join("") +
    "</tr>";
  head.querySelectorAll("th[data-sort]").forEach((th) => {
    th.addEventListener("click", () => {
      const key = th.dataset.sort;
      if (sortKey === key) sortDir = sortDir === "asc" ? "desc" : "asc";
      else {
        sortKey = key;
        sortDir = "asc";
      }
      page = 1;
      render();
    });
  });
}

function filteredRows() {
  const q = String(document.getElementById("filterSearch")?.value || "")
    .trim()
    .toLowerCase();
  const nation = document.getElementById("filterNation")?.value || "";
  const ownerFilter = document.getElementById("filterOwner")?.value || "";
  return allRows.filter((r) => {
    if (nation && String(r.nation || "") !== nation) return false;
    if (ownerFilter === "vacant" && !isVacant(r)) return false;
    if (ownerFilter === "owned" && isVacant(r)) return false;
    if (!q) return true;
    const hay = [
      r.club_name,
      r.club_short_name,
      r.stadium_name,
      r.nation,
      r.owner_tag,
      r.manager_name,
    ]
      .map((x) => String(x || "").toLowerCase())
      .join(" ");
    return hay.includes(q);
  });
}

function sortedRows(rows) {
  const dir = sortDir === "desc" ? -1 : 1;
  const key = sortKey;
  return [...rows].sort((a, b) => {
    const av = a[key];
    const bv = b[key];
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    if (typeof av === "number" || typeof bv === "number") {
      return (Number(av) - Number(bv)) * dir;
    }
    return String(av).localeCompare(String(bv), undefined, { sensitivity: "base" }) * dir;
  });
}

function render() {
  buildHead();
  const rows = sortedRows(filteredRows());
  const total = rows.length;
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (page > pages) page = pages;
  const start = (page - 1) * pageSize;
  const slice = rows.slice(start, start + pageSize);

  const body = document.getElementById("tableBody");
  if (!body) return;
  body.innerHTML = slice
    .map((r) => {
      const clubHref = `club.html?club=${encodeURIComponent(r.club_short_name || "")}`;
      const vacantBadge = isVacant(r) ? `<span class="vacant-badge">Vacant</span>` : "";
      return `<tr>
        <td class="left"><a class="club-link" href="${clubHref}">${escapeHtml(
          r.club_name || r.club_short_name
        )}</a>${vacantBadge}</td>
        <td class="left">${escapeHtml(r.stadium_name || "—")}</td>
        <td class="left">${escapeHtml(r.nation || "—")}</td>
        <td>${fmtInt(r.stadium_capacity)}</td>
        <td>${fmtInt(r.stadium_max_capacity)}</td>
        <td>${fmtInt(r.stadium_expansion_potential)}</td>
        <td class="left" title="${
          r.club_expectation != null ? `Baseline P${escapeHtml(String(r.club_expectation))}` : ""
        }">${escapeHtml(r.club_expectation_label || "—")}</td>
        <td title="Sum of contracted players’ market values">${moneyCell(r.club_market_value)}</td>
        <td title="Capacity × ₿1,500">${moneyCell(r.stadium_value)}</td>
        <td>${moneyCell(r.stadium_maintenance_cost)}</td>
        <td>${moneyCell(r.gate_money_full)}</td>
        <td>${moneyCell(r.gate_money_80)}</td>
        <td>${escapeHtml(r.owner_tag || (isVacant(r) ? "Vacant" : "—"))}</td>
        ${interestCellHtml(r)}
        <td>${r.prestige_rank != null ? escapeHtml(String(r.prestige_rank)) : "—"}</td>
      </tr>`;
    })
    .join("");

  body.querySelectorAll("[data-interest-club]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const short = btn.getAttribute("data-interest-club");
      const row = allRows.find((r) => r.club_short_name === short);
      if (row) openInterestModal(row);
    });
  });

  setStatus(`${total} clubs · page ${page}/${pages}`);

  const pager = document.getElementById("pager");
  if (pager) {
    pager.innerHTML = `
      <button type="button" class="button gpsl-view-ok" id="prevPage" ${page <= 1 ? "disabled" : ""}>Prev</button>
      <button type="button" class="button gpsl-view-ok" id="nextPage" ${page >= pages ? "disabled" : ""}>Next</button>
    `;
    document.getElementById("prevPage")?.addEventListener("click", () => {
      page -= 1;
      render();
    });
    document.getElementById("nextPage")?.addEventListener("click", () => {
      page += 1;
      render();
    });
  }
}

function selectedMarkKind() {
  const el = document.querySelector('input[name="cdbMarkKind"]:checked');
  return el?.value === "backup" ? "backup" : "interest";
}

function openInterestModal(row) {
  interestModalClub = row;
  const modal = document.getElementById("cdbInterestModal");
  const title = document.getElementById("cdbInterestModalTitle");
  const note = document.getElementById("cdbInterestNote");
  const err = document.getElementById("cdbInterestModalError");
  const saveBtn = document.getElementById("cdbInterestSaveBtn");
  const clearBtn = document.getElementById("cdbInterestClearBtn");
  const help = document.getElementById("cdbInterestModalHelp");
  if (!modal || !row) return;

  const mine = myMarkFor(row.club_short_name);
  const frozen = Boolean(interestState?.frozen);
  const canMark = Boolean(interestState?.can_mark);
  const kind = mine?.mark_kind === "backup" ? "backup" : "interest";

  const interestRadio = document.getElementById("cdbMarkInterest");
  const backupRadio = document.getElementById("cdbMarkBackup");
  if (interestRadio) interestRadio.checked = kind === "interest";
  if (backupRadio) backupRadio.checked = kind === "backup";
  if (interestRadio) interestRadio.disabled = frozen || !canMark;
  if (backupRadio) backupRadio.disabled = frozen || !canMark;

  if (title) {
    title.textContent = `${mine ? "Your mark" : "Mark club"} — ${row.club_name || row.club_short_name}`;
  }
  if (help) {
    help.textContent =
      "Choose Interest (primary) or Backup (1 of each). Marking a new club as Interest/Backup replaces your previous pick of that type.";
  }
  if (note) {
    note.value = mine?.note || "";
    note.disabled = frozen || (!canMark && !mine);
  }
  if (err) err.textContent = "";
  if (saveBtn) {
    saveBtn.disabled = frozen || !canMark;
    saveBtn.textContent = mine ? "Update mark" : "Save mark";
  }
  if (clearBtn) clearBtn.disabled = frozen || !mine;

  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
}

function closeInterestModal() {
  const modal = document.getElementById("cdbInterestModal");
  if (modal) {
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden", "true");
  }
  interestModalClub = null;
}

function wireInterestModal() {
  document.getElementById("cdbInterestModalClose")?.addEventListener("click", closeInterestModal);
  document.getElementById("cdbInterestModal")?.addEventListener("click", (e) => {
    if (e.target?.id === "cdbInterestModal") closeInterestModal();
  });

  document.getElementById("cdbInterestSaveBtn")?.addEventListener("click", async () => {
    if (!interestModalClub) return;
    const err = document.getElementById("cdbInterestModalError");
    const noteVal = document.getElementById("cdbInterestNote")?.value || "";
    const btn = document.getElementById("cdbInterestSaveBtn");
    if (btn) btn.disabled = true;
    if (err) err.textContent = "";
    const { data, error } = await supabase.rpc("club_auction_interest_set", {
      p_club_short_name: interestModalClub.club_short_name,
      p_note: noteVal.trim() || null,
      p_mark_kind: selectedMarkKind(),
    });
    if (btn) btn.disabled = false;
    if (error) {
      if (err) err.textContent = error.message;
      return;
    }
    interestState = data;
    renderInterestBanner();
    closeInterestModal();
    render();
  });

  document.getElementById("cdbInterestClearBtn")?.addEventListener("click", async () => {
    if (!interestModalClub) return;
    const err = document.getElementById("cdbInterestModalError");
    const btn = document.getElementById("cdbInterestClearBtn");
    if (btn) btn.disabled = true;
    if (err) err.textContent = "";
    const { data, error } = await supabase.rpc("club_auction_interest_clear", {
      p_club_short_name: interestModalClub.club_short_name,
    });
    if (btn) btn.disabled = false;
    if (error) {
      if (err) err.textContent = error.message;
      return;
    }
    interestState = data;
    renderInterestBanner();
    closeInterestModal();
    render();
  });
}

function fmtInt(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return Math.round(v).toLocaleString("en-GB");
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function fillNationFilter() {
  const sel = document.getElementById("filterNation");
  if (!sel) return;
  const nations = [...new Set(allRows.map((r) => r.nation).filter(Boolean))].sort((a, b) =>
    a.localeCompare(b)
  );
  const cur = sel.value;
  sel.innerHTML =
    `<option value="">All</option>` +
    nations.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join("");
  sel.value = cur;
}

async function loadClubs() {
  setError("");
  setStatus("Loading clubs…");
  const { data, error } = await supabase
    .from("clubs_database_public")
    .select("*")
    .order("prestige_rank", { ascending: true, nullsFirst: false });

  if (error) {
    setError(
      error.message +
        " — run supabase/sql/patches/clubs_database_public.sql in Supabase."
    );
    setStatus("");
    return;
  }
  allRows = data || [];
  fillNationFilter();
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  wireInterestModal();
  wireDiscordChatLinks();

  document.getElementById("filterSearch")?.addEventListener("input", () => {
    page = 1;
    render();
  });
  document.getElementById("filterNation")?.addEventListener("change", () => {
    page = 1;
    render();
  });
  document.getElementById("filterOwner")?.addEventListener("change", () => {
    page = 1;
    render();
  });
  document.getElementById("pageSize")?.addEventListener("change", (e) => {
    pageSize = Number(e.target.value) || 100;
    page = 1;
    render();
  });
  document.getElementById("clearFiltersBtn")?.addEventListener("click", () => {
    const s = document.getElementById("filterSearch");
    const n = document.getElementById("filterNation");
    const o = document.getElementById("filterOwner");
    if (s) s.value = "";
    if (n) n.value = "";
    if (o) o.value = "";
    page = 1;
    render();
  });

  await Promise.all([loadClubs(), loadInterestState()]);
  render();
});
