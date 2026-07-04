import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  loadAvailabilityContextForClub,
  saveWeeklyAvailabilityForClub,
  setClubTimezoneForClub,
} from "./match_scheduling.js";
import { mountAvailabilityPanel } from "./owner_availability.js";

primeAdminPageChrome();

let clubs = [];
let selectedClub = null;

function clubLabel(c) {
  const owner = c.owner_id ? "Owned" : "Unowned";
  const tz = c.owner_timezone || "Europe/London";
  return `${c.Club || c.ShortName} (${c.ShortName}) — ${owner} · ${tz.replace(/_/g, " ")}`;
}

function updateClubMeta() {
  const el = document.getElementById("clubMeta");
  const short = document.getElementById("clubSelect")?.value;
  const c = clubs.find((row) => row.ShortName === short);
  if (!el || !c) {
    if (el) el.textContent = "";
    return;
  }
  el.textContent = `Timezone: ${(c.owner_timezone || "Europe/London").replace(/_/g, " ")} · Owner linked: ${c.owner_id ? "yes" : "no"}`;
}

async function loadClubs() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club, owner_timezone, owner_id")
    .order("Club");
  if (error) throw error;
  clubs = data || [];

  const sel = document.getElementById("clubSelect");
  if (!sel) return;
  sel.innerHTML =
    '<option value="">— Select club —</option>' +
    clubs
      .map(
        (c) =>
          `<option value="${c.ShortName}">${clubLabel(c).replace(/</g, "&lt;")}</option>`
      )
      .join("");

  sel.onchange = () => {
    selectedClub = sel.value || null;
    updateClubMeta();
    void loadEditor();
  };
}

async function loadEditor() {
  const panel = document.getElementById("availabilityPanel");
  const root = document.getElementById("availabilityEditorRoot");
  const title = document.getElementById("availabilityPanelTitle");

  if (!selectedClub || !panel || !root) {
    if (panel) panel.classList.remove("visible");
    return;
  }

  const club = clubs.find((c) => c.ShortName === selectedClub);
  if (title) {
    title.textContent = `Availability — ${club?.Club || selectedClub}`;
  }

  panel.classList.add("visible");
  root.innerHTML = "<p class=\"note\">Loading…</p>";

  await mountAvailabilityPanel(root, {
    loadContext: () => loadAvailabilityContextForClub(selectedClub),
    saveWeekly: (slots) => saveWeeklyAvailabilityForClub(selectedClub, slots),
    setTimezone: (tz) => setClubTimezoneForClub(selectedClub, tz),
  });

  const c = clubs.find((row) => row.ShortName === selectedClub);
  if (c) {
    try {
      const ctx = await loadAvailabilityContextForClub(selectedClub);
      c.owner_timezone = ctx.timezone;
      updateClubMeta();
    } catch {
      /* ignore refresh errors */
    }
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await initAdminPage();
  if (!user) return;

  try {
    await loadClubs();
  } catch (err) {
    setStatus("loadStatus", "Load failed — run admin_club_availability.sql if RPCs are missing. " + err.message, false);
  }
});
