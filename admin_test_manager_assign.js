import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const GPSL_MONTHS = [
  { value: "august", label: "August" },
  { value: "september", label: "September" },
  { value: "october", label: "October" },
  { value: "november", label: "November" },
  { value: "december", label: "December" },
  { value: "january", label: "January" },
  { value: "february", label: "February" },
  { value: "march", label: "March" },
  { value: "april", label: "April" },
  { value: "may", label: "May" },
];

let managers = [];
let clubs = [];

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return "₿" + Math.round(v).toLocaleString("en-GB");
}

function managerLabel(m) {
  const club = m.contracted_club ? m.contracted_club : "FREE";
  return `${m.name} (${m.rating}) — ${club}`;
}

function clubLabel(c) {
  const mgr = c.manager_name ? c.manager_name : "No manager";
  const owner = c.owner_label || "Unowned";
  return `${c.club_name || c.club_short_name} — ${owner} — ${mgr}`;
}

function updateManagerMeta() {
  const el = document.getElementById("managerMeta");
  const id = document.getElementById("managerSelect")?.value;
  const m = managers.find((row) => String(row.id) === String(id));
  if (!el || !m) {
    if (el) el.textContent = "";
    return;
  }
  const club = m.contracted_club ? m.contracted_club : "Free agent";
  el.textContent = `${m.nation || "—"} · MV ${formatMoney(m.market_value)} · ${club}`;
}

function updateClubMeta() {
  const el = document.getElementById("clubMeta");
  const short = document.getElementById("clubSelect")?.value;
  const c = clubs.find((row) => row.club_short_name === short);
  if (!el || !c) {
    if (el) el.textContent = "";
    return;
  }
  const mgr = c.manager_name
    ? `${c.manager_name} (${c.manager_rating})`
    : "Vacant";
  el.textContent = `Owner: ${c.owner_label || "Unowned"} · Manager: ${mgr}`;
}

async function loadManagers() {
  const { data, error } = await supabase
    .from("managers_gpdb_public")
    .select("id,name,nation,rating,market_value,contracted_club")
    .order("name");
  if (error) throw error;
  managers = data || [];
  const sel = document.getElementById("managerSelect");
  if (!sel) return;
  sel.innerHTML =
    '<option value="">— Select manager —</option>' +
    managers
      .map(
        (m) =>
          `<option value="${m.id}">${managerLabel(m).replace(/</g, "&lt;")}</option>`
      )
      .join("");
}

async function loadClubs() {
  const [
    { data: clubRows, error: clubErr },
    { data: mgrRows, error: mgrErr },
    { data: ownerRows, error: ownerErr },
  ] = await Promise.all([
    supabase
      .from("Clubs")
      .select("ShortName, Club, manager_id, owner_id, owner")
      .order("Club"),
    supabase.from("Managers").select("id, name, rating").not("id", "is", null),
    supabase.rpc("admin_owner_list"),
  ]);
  if (clubErr) throw clubErr;
  if (mgrErr) throw mgrErr;
  if (ownerErr) {
    console.warn("admin_owner_list:", ownerErr);
  }

  const ownerByClub = new Map();
  for (const row of ownerRows || []) {
    if (!row.club_short_name) continue;
    const tag = row.owner_tag ? `@${row.owner_tag.replace(/^@/, "")}` : "";
    ownerByClub.set(
      row.club_short_name,
      tag || row.email || "Owner linked"
    );
  }

  const mgrById = new Map((mgrRows || []).map((m) => [m.id, m]));
  clubs = (clubRows || []).map((c) => {
    const mgr = c.manager_id ? mgrById.get(c.manager_id) : null;
    const ownerLabel =
      ownerByClub.get(c.ShortName) ||
      (c.owner_id
        ? c.owner
          ? `@${String(c.owner).replace(/^@/, "")}`
          : "Owner linked"
        : null);
    return {
      club_short_name: c.ShortName,
      club_name: c.Club,
      manager_name: mgr?.name || null,
      manager_rating: mgr?.rating || null,
      owner_label: ownerLabel,
      division: null,
    };
  });
  const sel = document.getElementById("clubSelect");
  if (!sel) return;
  sel.innerHTML =
    '<option value="">— Select club —</option>' +
    clubs
      .map(
        (c) =>
          `<option value="${c.club_short_name}">${clubLabel(c).replace(/</g, "&lt;")}</option>`
      )
      .join("");
}

async function assignManager() {
  const managerId = document.getElementById("managerSelect")?.value;
  const clubShort = document.getElementById("clubSelect")?.value;
  const seasons = Number(document.getElementById("seasonsInput")?.value || 2);
  const releaseClubMgr = !!document.getElementById("releaseClubMgr")?.checked;
  const releaseMgrContract = !!document.getElementById("releaseMgrContract")?.checked;
  const waiveFee = !!document.getElementById("waiveFee")?.checked;

  if (!managerId || !clubShort) {
    setStatus("assignStatus", "Select a manager and a club.", false);
    return;
  }

  const m = managers.find((row) => String(row.id) === String(managerId));
  const c = clubs.find((row) => row.club_short_name === clubShort);
  const msg = `Assign ${m?.name || "manager"} to ${c?.club_name || clubShort}?`;
  if (!confirm(msg)) return;

  setStatus("assignStatus", "Assigning…");
  const { data, error } = await supabase.rpc("admin_testing_assign_manager", {
    p_manager_id: Number(managerId),
    p_club_short: clubShort,
    p_seasons: seasons,
    p_release_club_manager: releaseClubMgr,
    p_release_manager_contract: releaseMgrContract,
    p_waive_fee: waiveFee,
  });

  if (error) {
    setStatus("assignStatus", error.message, false);
    return;
  }

  if (data?.already_assigned) {
    setStatus(
      "assignStatus",
      `${data?.manager_name || m?.name} is already at ${data?.club || clubShort}.`,
      true
    );
    return;
  }

  setStatus(
    "assignStatus",
    `Assigned ${data?.manager_name || m?.name} to ${data?.club || clubShort}.`,
    true
  );
  await loadManagers();
  await loadClubs();
  document.getElementById("managerSelect").value = managerId;
  document.getElementById("clubSelect").value = clubShort;
  updateManagerMeta();
  updateClubMeta();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  try {
    await Promise.all([loadManagers(), loadClubs()]);
    setStatus("assignStatus", "Ready.");
  } catch (err) {
    setStatus(
      "assignStatus",
      "Load failed — run admin_testing_tools.sql if RPCs are missing. " +
        (err?.message || err),
      false
    );
  }

  document.getElementById("managerSelect")?.addEventListener("change", updateManagerMeta);
  document.getElementById("clubSelect")?.addEventListener("change", updateClubMeta);
  document.getElementById("assignBtn")?.addEventListener("click", assignManager);
});
