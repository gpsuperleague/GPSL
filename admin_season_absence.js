import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

function setStatus(msg, ok = true) {
  const el = document.getElementById("absStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.style.color = ok ? "#9fd4b0" : "#f88";
}

function money(n) {
  if (n == null || !Number.isFinite(Number(n))) return "—";
  return `₿${Number(n).toLocaleString("en-GB")}`;
}

function statusClass(s) {
  if (s === "active") return "abs-status abs-status--active";
  if (s === "requested") return "abs-status abs-status--requested";
  if (s === "completed") return "abs-status abs-status--completed";
  return "abs-status";
}

async function loadClubOptions() {
  const sel = document.getElementById("absClub");
  if (!sel) return;
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club, owner_id, owner")
    .not("owner_id", "is", null)
    .order("Club");
  if (error) {
    sel.innerHTML = `<option value="">${error.message}</option>`;
    return;
  }
  sel.innerHTML =
    `<option value="">Select club…</option>` +
    (data || [])
      .map(
        (c) =>
          `<option value="${c.ShortName}">${c.Club || c.ShortName} (${c.ShortName})${
            c.owner ? ` — ${c.owner}` : ""
          }</option>`
      )
      .join("");
}

async function refreshList() {
  const body = document.getElementById("absBody");
  if (!body) return;
  body.innerHTML = `<tr><td colspan="6">Loading…</td></tr>`;

  const { data, error } = await supabase.rpc("admin_club_season_absence_list");
  if (error) {
    body.innerHTML = `<tr><td colspan="6" style="color:#f88">${error.message}</td></tr>`;
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    body.innerHTML = `<tr><td colspan="6">No absence records this season.</td></tr>`;
    return;
  }

  body.innerHTML = rows
    .map((r) => {
      const actions = [];
      if (r.status === "requested") {
        actions.push(
          `<button type="button" class="button" data-approve="${r.club_short_name}">Approve</button>`
        );
        actions.push(
          `<button type="button" class="button danger" data-reject="${r.id}">Reject</button>`
        );
      }
      if (r.status === "active") {
        actions.push(
          `<button type="button" class="button secondary" data-return="${r.club_short_name}">End early</button>`
        );
      }
      return `
        <tr>
          <td><b>${fullClubName(r.club_short_name) || r.club_name || r.club_short_name}</b><br>
            <span style="color:#888;font-size:11px">${r.club_short_name}</span></td>
          <td>${r.owner_tag || "—"}</td>
          <td><span class="${statusClass(r.status)}">${r.status}</span></td>
          <td>${money(r.club_balance)}</td>
          <td style="font-size:12px;color:#aaa">${
            r.activated_at
              ? new Date(r.activated_at).toLocaleString("en-GB")
              : r.requested_at
                ? `req ${new Date(r.requested_at).toLocaleString("en-GB")}`
                : "—"
          }</td>
          <td class="abs-actions">${actions.join(" ") || "—"}</td>
        </tr>`;
    })
    .join("");
}

async function activate(club, note) {
  const { data, error } = await supabase.rpc("admin_club_season_absence_activate", {
    p_club_short_name: club,
    p_note: note || null,
  });
  if (error) throw error;
  return data;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  // isGpslAdminUser(user) needs the auth user — bare call always returns false
  if (!isGpslAdminUser(user)) {
    document.getElementById("adminMain").innerHTML =
      '<p class="note" style="color:#f88">Admin only.</p>';
    return;
  }

  await loadClubOptions();
  await refreshList();

  document.getElementById("absRefreshBtn")?.addEventListener("click", () => {
    refreshList().catch((e) => setStatus(e.message, false));
  });

  document.getElementById("absActivateBtn")?.addEventListener("click", async () => {
    const club = document.getElementById("absClub")?.value;
    const note = document.getElementById("absNote")?.value || "";
    if (!club) {
      setStatus("Pick a club.", false);
      return;
    }
    if (
      !confirm(
        `Activate season absence for ${club}?\n\nManager will be released for MV into the club balance. Finances/loans freeze. Fixtures will be awarded.`
      )
    ) {
      return;
    }
    try {
      setStatus("Activating…");
      const data = await activate(club, note);
      setStatus(
        `Active for ${data?.club || club}` +
          (data?.ffp_at_risk ? " · FFP at risk (≤ −₿100m)" : "") +
          (data?.manager_release?.ok === false
            ? ` · manager release: ${data.manager_release.error || "failed"}`
            : data?.manager_release?.ok
              ? " · manager released"
              : " · no manager")
      );
      await refreshList();
    } catch (e) {
      setStatus(e.message || String(e), false);
    }
  });

  document.getElementById("absBody")?.addEventListener("click", async (ev) => {
    const t = ev.target;
    if (!(t instanceof HTMLElement)) return;
    try {
      if (t.dataset.approve) {
        if (!confirm(`Approve & activate absence for ${t.dataset.approve}?`)) return;
        setStatus("Approving…");
        await activate(t.dataset.approve, null);
        setStatus("Activated.");
        await refreshList();
      } else if (t.dataset.reject) {
        const note = prompt("Reject note (optional)") || null;
        const { error } = await supabase.rpc("admin_club_season_absence_reject", {
          p_id: Number(t.dataset.reject),
          p_note: note,
        });
        if (error) throw error;
        setStatus("Rejected.");
        await refreshList();
      } else if (t.dataset.return) {
        if (!confirm(`End season absence early for ${t.dataset.return}?`)) return;
        const { error } = await supabase.rpc("club_season_absence_return", {
          p_club_short_name: t.dataset.return,
        });
        if (error) throw error;
        setStatus("Absence ended — remaining fixtures live again.");
        await refreshList();
      }
    } catch (e) {
      setStatus(e.message || String(e), false);
    }
  });
});
