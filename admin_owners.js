import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let clubAuctionStartingBalance = 600000000;

function formatBudgetLabel(n) {
  const v = Math.round(Number(n) || 0);
  if (v >= 1_000_000) return `₿${(v / 1_000_000).toLocaleString("en-GB")}m`;
  return `₿${v.toLocaleString("en-GB")}`;
}

async function loadClubAuctionConfig() {
  const { data } = await supabase.rpc("club_auction_get_config");
  if (data?.starting_balance > 0) {
    clubAuctionStartingBalance = Math.round(Number(data.starting_balance));
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadClubAuctionConfig();
  await loadOwnerList();

  document.getElementById("addOwnerBtn").onclick = addOwner;
  document.getElementById("changeOwnerBtn").onclick = changeOwnerClub;
  document.getElementById("clubAuctionRegisterBtn").onclick = registerForClubAuction;
  document.getElementById("linkOwnerBtn").onclick = linkOwner;
  document.getElementById("breakOwnerBtn").onclick = removeFromClub;
  document.getElementById("archiveOwnerBtn").onclick = archiveOwner;
  document.getElementById("unarchiveOwnerBtn").onclick = unarchiveOwner;
  document.getElementById("updateEmailBtn").onclick = updateEmail;
  document.getElementById("setOwnerTagBtn").onclick = setOwnerTag;
  document.getElementById("tagOwnerSelect")?.addEventListener("change", syncOwnerTagInputFromSelect);
  document.getElementById("setPasswordBtn").onclick = setOwnerPassword;
  document.getElementById("resetPasswordBtn").onclick = resetPassword;

  document.getElementById("wlRefreshBtn")?.addEventListener("click", loadWaitingListAdmin);
  document.getElementById("wlRestoreOrderBtn")?.addEventListener("click", restoreWaitingListOrder);
  document.getElementById("wlInviteAuctionBtn")?.addEventListener("click", inviteWaitingListAuction);
  document.getElementById("wlDirectAssignBtn")?.addEventListener("click", directAssignFromWaitingList);
  document.getElementById("wlAbsenceOnBtn")?.addEventListener("click", () => setWaitingListAbsence(true));
  document.getElementById("wlAbsenceOffBtn")?.addEventListener("click", () => setWaitingListAbsence(false));

  await loadWaitingListAdmin();
});

async function loadOwnerList() {
  const dropdown = document.getElementById("updateOwnerSelect");
  const tagDropdown = document.getElementById("tagOwnerSelect");

  const owners = await fetchAdminOwnerRows();
  if (!owners.length) {
    const errHtml = `<option>Error loading owners</option>`;
    if (dropdown) dropdown.innerHTML = errHtml;
    if (tagDropdown) tagDropdown.innerHTML = errHtml;
    return;
  }

  if (dropdown) dropdown.innerHTML = "";
  if (tagDropdown) tagDropdown.innerHTML = "";

  const statusLabel = (row) => {
    if (row.clubShortName) return row.clubShortName;
    if (row.registryStatus === "archived") {
      return `ARCHIVED (${row.lastClubShortName || "?"})`;
    }
    if (row.registryStatus === "on_break") {
      return `ON BREAK (${row.lastClubShortName || "?"})`;
    }
    if (row.registryStatus === "member") return "WAITING LIST";
    if (row.registryStatus === "on_absence") return "ABSENCE";
    if (row.registryStatus === "awaiting_club_auction") return "CLUB AUCTION";
    return "NO CLUB";
  };

  const formatTagOptionLabel = (shortName, email, tag) => {
    if (tag) return `${shortName} — ${tag} — ${email}`;
    return `${shortName} — no tag — ${email}`;
  };

  owners.forEach((row) => {
    const shortName = statusLabel(row);
    const currentTag = String(row.ownerTag || "").trim();
    const option = document.createElement("option");
    option.value = row.id;
    option.textContent = `${shortName} — ${row.email}`;
    dropdown?.appendChild(option);

    if (tagDropdown) {
      const tagOption = document.createElement("option");
      tagOption.value = row.email;
      tagOption.dataset.ownerId = row.id;
      tagOption.textContent = formatTagOptionLabel(shortName, row.email, currentTag);
      if (currentTag) tagOption.dataset.currentTag = currentTag;
      tagDropdown.appendChild(tagOption);
    }
  });

  await syncOwnerTagInputFromSelect();
}

async function fetchAdminOwnerRows() {
  const { data: rpcOwners, error: rpcError } = await supabase.rpc("admin_owner_list");
  const byId = new Map();

  if (!rpcError && rpcOwners?.length) {
    for (const row of rpcOwners) {
      byId.set(row.owner_id, {
        id: row.owner_id,
        email: row.email,
        clubShortName: row.club_short_name || null,
        lastClubShortName: row.club_short_name || null,
        ownerTag: row.owner_tag || "",
        registryStatus: row.registry_status || null,
      });
    }
  }

  const { data: ownerData } = await supabase.functions.invoke("list-owners");
  if (ownerData?.users?.length) {
    const { data: registry } = await supabase
      .from("gpsl_owner_registry")
      .select("owner_id, status, last_club_short_name, owner_tag");
    const { data: clubs } = await supabase.from("Clubs").select("ShortName, owner_id, owner");

    for (const u of ownerData.users) {
      if (byId.has(u.id)) continue;
      const club = clubs?.find((c) => c.owner_id === u.id);
      const reg = registry?.find((r) => r.owner_id === u.id);
      byId.set(u.id, {
        id: u.id,
        email: u.email,
        clubShortName: club?.ShortName || null,
        lastClubShortName: reg?.last_club_short_name || club?.ShortName || null,
        ownerTag: reg?.owner_tag || club?.owner || "",
        registryStatus: reg?.status || null,
      });
    }
  }

  return [...byId.values()].sort((a, b) => {
    const ak = (a.clubShortName || a.lastClubShortName || a.email || "").toLowerCase();
    const bk = (b.clubShortName || b.lastClubShortName || b.email || "").toLowerCase();
    return ak.localeCompare(bk) || String(a.email).localeCompare(String(b.email));
  });
}

async function syncOwnerTagInputFromSelect() {
  const tagDropdown = document.getElementById("tagOwnerSelect");
  const tagInput = document.getElementById("ownerTagInput");
  const hint = document.getElementById("currentTagHint");
  if (!tagDropdown || !tagInput) return;

  const opt = tagDropdown.selectedOptions[0];
  let currentTag = opt?.dataset?.currentTag || "";

  const ownerId = opt?.dataset?.ownerId;
  if (ownerId) {
    const { data, error } = await supabase.rpc("owner_registry_resolve_tag", {
      p_owner_id: ownerId,
    });
    if (!error && data) {
      currentTag = String(data).trim();
      if (currentTag) opt.dataset.currentTag = currentTag;
    }
  }

  tagInput.value = currentTag;
  tagInput.placeholder = currentTag ? currentTag : "e.g. @username";
  if (hint) {
    hint.textContent = currentTag ? `Current tag: ${currentTag}` : "No tag set for this owner.";
  }
}

async function setOwnerTag() {
  const email = document.getElementById("tagOwnerSelect")?.value?.trim();
  const tag = document.getElementById("ownerTagInput")?.value?.trim();

  if (!email || email.includes("Error")) {
    setStatus("setOwnerTagStatus", "Select an owner.", false);
    return;
  }
  if (!tag) {
    setStatus("setOwnerTagStatus", "Enter a Discord tag.", false);
    return;
  }

  setStatus("setOwnerTagStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_owner_set_tag", {
    p_owner_email: email,
    p_tag: tag,
  });

  if (error) {
    const hint =
      error.message?.includes("admin_owner_set_tag") ||
      error.message?.includes("function")
        ? " — re-run patches/admin_owner_set_tag.sql in Supabase"
        : "";
    setStatus("setOwnerTagStatus", "❌ " + error.message + hint, false);
    return;
  }

  const clubNote = data?.club_short_name ? ` (${data.club_short_name})` : "";
  setStatus(
    "setOwnerTagStatus",
    `✅ Tag set to ${data?.owner_tag || tag} for ${data?.email || email}${clubNote}`,
    true
  );
  await loadOwnerList();
}

async function addOwner() {
  const email = document.getElementById("ownerEmail").value.trim();
  const password = document.getElementById("ownerPassword").value.trim();
  const club = document.getElementById("ownerClub").value.trim();

  if (!email || !password || !club) {
    setStatus("ownerStatus", "Fill all fields (email, password, and club ShortName).", false);
    return;
  }

  setStatus("ownerStatus", "Creating login…");
  const { error } = await supabase.functions.invoke("create-owner", {
    body: { email, password, clubShortName: club },
  });

  if (error) {
    setStatus("ownerStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("ownerStatus", "Login created — linking club…");
  const { data, error: linkErr } = await supabase.rpc("admin_assign_club_owner", {
    p_owner_email: email,
    p_club_short_name: club,
  });

  if (linkErr) {
    setStatus(
      "ownerStatus",
      `⚠️ Login created for ${email}, but club link failed: ${linkErr.message}. Use Link existing login to club.`,
      false
    );
    await loadOwnerList();
    return;
  }

  setStatus(
    "ownerStatus",
    `✅ ${email} created and linked to ${data?.club_name || club}.`,
    true
  );
  await loadOwnerList();
}

async function removeFromClub() {
  const email = document.getElementById("breakOwnerEmail")?.value?.trim();
  if (!email) {
    setStatus("breakOwnerStatus", "Enter owner email.", false);
    return;
  }
  if (
    !confirm(
      `Remove ${email} from their club?\n\nClub and nation links will clear. History is kept. They can return via Link club.`
    )
  ) {
    return;
  }
  setStatus("breakOwnerStatus", "Removing…");
  const { data, error } = await supabase.rpc("admin_owner_remove_from_club", {
    p_owner_email: email,
  });
  if (error) {
    setStatus("breakOwnerStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "breakOwnerStatus",
    `✅ ${data?.owner_tag || email} removed from ${data?.club_name || data?.club_short_name || "club"}${
      data?.nation_code ? ` · nation ${data.nation_code} released` : ""
    }`,
    true
  );
  await loadOwnerList();
}

async function archiveOwner() {
  const email = document.getElementById("archiveOwnerEmail")?.value?.trim();
  const note = document.getElementById("archiveOwnerNote")?.value?.trim() || null;
  if (!email) {
    setStatus("archiveOwnerStatus", "Enter owner email.", false);
    return;
  }
  if (
    !confirm(
      `Archive ${email}?\n\nThey will be detached from club and nation. Unarchive before linking a club again.`
    )
  ) {
    return;
  }
  setStatus("archiveOwnerStatus", "Archiving…");
  const { data, error } = await supabase.rpc("admin_owner_archive", {
    p_owner_email: email,
    p_note: note,
  });
  if (error) {
    setStatus("archiveOwnerStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "archiveOwnerStatus",
    `✅ Archived ${data?.owner_tag || email} (was ${data?.club_short_name || "club"})`,
    true
  );
  await loadOwnerList();
}

async function unarchiveOwner() {
  const email = document.getElementById("unarchiveOwnerEmail")?.value?.trim();
  if (!email) {
    setStatus("unarchiveOwnerStatus", "Enter owner email.", false);
    return;
  }
  setStatus("unarchiveOwnerStatus", "Unarchiving…");
  const { data, error } = await supabase.rpc("admin_owner_unarchive", {
    p_owner_email: email,
  });
  if (error) {
    setStatus("unarchiveOwnerStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "unarchiveOwnerStatus",
    `✅ ${data?.email || email} unarchived — link a club when ready`,
    true
  );
  await loadOwnerList();
}

async function changeOwnerClub() {
  const email = document.getElementById("changeOwnerEmail")?.value?.trim();
  const club = document.getElementById("changeOwnerClub")?.value?.trim();
  if (!email || !club) {
    setStatus("changeOwnerStatus", "Enter email and new club ShortName.", false);
    return;
  }
  if (
    !confirm(
      `Move ${email} to ${club.toUpperCase()}?\n\nTheir current club will be vacated (nation released). If ${club.toUpperCase()} has another owner, that owner goes on break.`
    )
  ) {
    return;
  }
  setStatus("changeOwnerStatus", "Changing…");
  const { data, error } = await supabase.rpc("admin_owner_change_club", {
    p_owner_email: email,
    p_new_club_short_name: club,
  });
  if (error) {
    setStatus("changeOwnerStatus", "❌ " + error.message, false);
    return;
  }
  let msg = `✅ ${data?.from_club_short_name || "?"} → ${data?.to_club_name || data?.to_club_short_name || club}`;
  if (data?.released_nation) msg += ` · released ${data.released_nation} from old club`;
  if (data?.displaced_owner_email) msg += ` · displaced ${data.displaced_owner_email} (on break)`;
  setStatus("changeOwnerStatus", msg, true);
  await loadOwnerList();
}

async function invokeEdgeFunction(name, body) {
  const { data, error } = await supabase.functions.invoke(name, { body });
  if (error) {
    let detail = error.message || "Request failed";
    try {
      const ctx = error.context;
      if (ctx && typeof ctx.json === "function") {
        const payload = await ctx.json();
        if (payload?.error) detail = String(payload.error);
      }
    } catch {
      /* ignore */
    }
    if (data?.error) detail = String(data.error);
    return { data, error: new Error(detail) };
  }
  if (data?.error) {
    return { data, error: new Error(String(data.error)) };
  }
  return { data, error: null };
}

async function registerForClubAuction() {
  const email = document.getElementById("clubAuctionEmail")?.value?.trim().toLowerCase();
  const password = document.getElementById("clubAuctionPassword")?.value?.trim() || "";
  const registerOnly =
    document.getElementById("clubAuctionRegisterOnly")?.checked === true;

  if (!email) {
    setStatus("clubAuctionStatus", "Enter owner email.", false);
    return;
  }

  if (!registerOnly && password.length < 6) {
    setStatus("clubAuctionStatus", "Password must be at least 6 characters.", false);
    return;
  }

  setStatus("clubAuctionStatus", registerOnly ? "Registering existing account…" : "Creating owner…");

  const { data, error } = await invokeEdgeFunction("create-owner-club-auction", {
    email,
    password: registerOnly ? undefined : password,
    startingBalance: clubAuctionStartingBalance,
    registerOnly,
  });

  if (error) {
    const hint =
      error.message?.includes("404") || error.message?.includes("not found")
        ? " — deploy create-owner-club-auction edge function in Supabase"
        : "";
    setStatus("clubAuctionStatus", "❌ " + error.message + hint, false);
    return;
  }

  if (document.getElementById("clubAuctionEmail")) {
    document.getElementById("clubAuctionEmail").value = "";
  }
  if (document.getElementById("clubAuctionPassword")) {
    document.getElementById("clubAuctionPassword").value = "";
  }

  const action = data?.register_only
    ? "registered (existing login kept)"
    : data?.auth_created
      ? "created"
      : data?.password_updated
        ? "updated"
        : "registered";

  setStatus(
    "clubAuctionStatus",
    `✅ ${email} ${action} — added to the bottom of the waiting list. Share login details; they start at member_home.html.`,
    true
  );
  await loadOwnerList();
}

async function linkOwner() {
  const email = document.getElementById("linkOwnerEmail").value.trim();
  const club = document.getElementById("linkOwnerClub").value.trim();

  if (!email || !club) {
    setStatus("linkOwnerStatus", "Enter email and club ShortName.", false);
    return;
  }

  setStatus("linkOwnerStatus", "Linking…");
  const { data, error } = await supabase.rpc("admin_assign_club_owner", {
    p_owner_email: email,
    p_club_short_name: club,
  });

  if (error) {
    setStatus("linkOwnerStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "linkOwnerStatus",
    `✅ ${data?.club_name || club} → ${data?.email || email}`,
    true
  );
  await loadOwnerList();
}

async function updateEmail() {
  const userId = document.getElementById("updateOwnerSelect").value;
  const newEmail = document.getElementById("newOwnerEmail").value.trim();

  if (!userId || !newEmail) {
    setStatus("updateEmailStatus", "Enter both fields.", false);
    return;
  }

  setStatus("updateEmailStatus", "Updating…");
  const { error } = await supabase.functions.invoke("update-owner-email", {
    body: { user_id: userId, new_email: newEmail },
  });

  setStatus("updateEmailStatus", error ? "❌ " + error.message : "✅ Email updated.", !error);
}

async function setOwnerPassword() {
  const email = document.getElementById("setPasswordEmail")?.value?.trim().toLowerCase();
  const password = document.getElementById("setPasswordValue")?.value?.trim() || "";

  if (!email) {
    setStatus("setPasswordStatus", "Enter owner email.", false);
    return;
  }
  if (password.length < 8) {
    setStatus(
      "setPasswordStatus",
      "Password must be at least 8 characters (use letters and numbers for Supabase).",
      false
    );
    return;
  }
  if (
    !confirm(
      `Set a new login password for ${email}?\n\nThey will use this on login.html. Share it securely.`
    )
  ) {
    return;
  }

  setStatus("setPasswordStatus", "Setting password…");
  const { data, error } = await invokeEdgeFunction("set-owner-password", {
    email,
    password,
  });

  if (error) {
    const hint =
      error.message?.includes("404") || error.message?.includes("not found")
        ? " — deploy set-owner-password edge function in Supabase"
        : "";
    setStatus("setPasswordStatus", "❌ " + error.message + hint, false);
    return;
  }

  if (document.getElementById("setPasswordValue")) {
    document.getElementById("setPasswordValue").value = "";
  }
  setStatus(
    "setPasswordStatus",
    `✅ Password updated for ${data?.email || email}. Test at login.html`,
    true
  );
}

async function resetPassword() {
  const email = document.getElementById("resetOwnerEmail").value.trim();
  if (!email) {
    setStatus("resetPasswordStatus", "Enter email.", false);
    return;
  }

  setStatus("resetPasswordStatus", "Sending…");
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: "https://gpsuperleague.github.io/GPSL/reset_password.html",
  });

  setStatus("resetPasswordStatus", error ? "❌ " + error.message : "✅ Reset email sent.", !error);
}

function setWlActionStatus(msg, ok) {
  setStatus("wlActionStatus", msg, ok);
}

async function loadWaitingListAdmin() {
  const tableWrap = document.getElementById("wlAdminTableWrap");
  const auctionWrap = document.getElementById("wlAuctionInviteWrap");
  if (!tableWrap) return;

  tableWrap.innerHTML = "<p class='note'>Loading…</p>";
  const { data, error } = await supabase.rpc("waiting_list_admin");
  if (error) {
    tableWrap.innerHTML = `<p class="note" style="color:#f88">❌ ${error.message} — run gpsl_waiting_list.sql</p>`;
    return;
  }

  const rows = data?.waiting || [];
  if (!rows.length) {
    tableWrap.innerHTML = "<p class='note'>No one on the waiting list.</p>";
  } else {
    let html =
      "<table class='admin-table' style='width:100%;font-size:13px;border-collapse:collapse'>" +
      "<thead><tr><th>#</th><th>Tag</th><th>Email</th><th>Tier</th><th>Status</th><th></th></tr></thead><tbody>";
    for (const row of rows) {
      const email = row.email || "";
      html += `<tr>
        <td>${row.position}</td>
        <td>${escapeWl(row.owner_tag)}</td>
        <td>${escapeWl(email)}</td>
        <td>${escapeWl(row.tier || "—")}</td>
        <td>${escapeWl(row.status)}</td>
        <td style="white-space:nowrap">
          <button type="button" class="button secondary wl-up" data-id="${row.owner_id}" data-email="${escapeWl(email)}">↑</button>
          <button type="button" class="button secondary wl-down" data-id="${row.owner_id}" data-email="${escapeWl(email)}">↓</button>
        </td>
      </tr>`;
    }
    html += "</tbody></table>";
    tableWrap.innerHTML = html;

    tableWrap.querySelectorAll(".wl-up").forEach((btn) => {
      btn.addEventListener("click", () => moveWaitingList(btn.dataset.id, -1));
    });
    tableWrap.querySelectorAll(".wl-down").forEach((btn) => {
      btn.addEventListener("click", () => moveWaitingList(btn.dataset.id, 1));
    });
  }

  const invited = data?.invited_to_auction || [];
  if (!auctionWrap) return;
  if (!invited.length) {
    auctionWrap.innerHTML = "<p class='note'>No one currently invited to club auction.</p>";
    return;
  }
  auctionWrap.innerHTML = invited
    .map(
      (r) =>
        `<div class="note">${escapeWl(r.owner_tag || "—")} — ${escapeWl(r.email)} — <code>awaiting_club_auction</code></div>`
    )
    .join("");
}

function escapeWl(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

async function moveWaitingList(ownerId, direction) {
  const { error } = await supabase.rpc("admin_waiting_list_move", {
    p_owner_id: ownerId,
    p_direction: direction,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  setWlActionStatus("✅ Order updated.", true);
}

async function restoreWaitingListOrder() {
  setWlActionStatus("Restoring…");
  const { error } = await supabase.rpc("admin_waiting_list_restore_join_order");
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  setWlActionStatus("✅ Join-date order restored (admin overrides cleared).", true);
}

function wlActionEmail() {
  return document.getElementById("wlActionEmail")?.value?.trim() || "";
}

async function inviteWaitingListAuction() {
  const email = wlActionEmail();
  if (!email) {
    setWlActionStatus("Enter member email.", false);
    return;
  }
  setWlActionStatus("Inviting…");
  const { error } = await supabase.rpc("admin_waiting_list_invite_auction", {
    p_owner_email: email,
    p_starting_balance: clubAuctionStartingBalance,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  await loadOwnerList();
  setWlActionStatus(`✅ ${email} invited to club auction.`, true);
}

async function directAssignFromWaitingList() {
  const email = wlActionEmail();
  const club = document.getElementById("wlAssignClub")?.value?.trim();
  if (!email || !club) {
    setWlActionStatus("Enter member email and club ShortName.", false);
    return;
  }
  setWlActionStatus("Assigning…");
  const { error } = await supabase.rpc("admin_waiting_list_assign_club", {
    p_owner_email: email,
    p_club_short_name: club,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  await loadOwnerList();
  setWlActionStatus(`✅ ${email} assigned to ${club.toUpperCase()}.`, true);
}

async function setWaitingListAbsence(on) {
  const email = wlActionEmail();
  if (!email) {
    setWlActionStatus("Enter member email.", false);
    return;
  }
  const note = on ? "Marked on absence by admin" : null;
  const { error } = await supabase.rpc("admin_waiting_list_set_absence", {
    p_owner_email: email,
    p_on_absence: on,
    p_note: note,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  setWlActionStatus(on ? `✅ ${email} marked on absence.` : `✅ Absence cleared for ${email}.`, true);
}
