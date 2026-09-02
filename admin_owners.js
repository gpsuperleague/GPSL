import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let clubAuctionStartingBalance = 650000000;

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
  if (!(await initAdminPage({ allowMod: true }))) return;

  const needsAuctionConfig = !!document.getElementById("clubAuctionRegisterBtn");
  const needsOwnerList =
    !!document.getElementById("updateOwnerSelect") ||
    !!document.getElementById("tagOwnerSelect") ||
    !!document.getElementById("archiveOwnerSelect") ||
    !!document.getElementById("unarchiveOwnerSelect");
  const needsWaitingList = !!document.getElementById("wlAdminTableWrap");
  const needsClubOwnerRemove = !!document.getElementById("clubOwnersTableWrap");

  if (needsAuctionConfig) await loadClubAuctionConfig();
  if (needsOwnerList) await loadOwnerList();

  const bind = (id, fn) => {
    const el = document.getElementById(id);
    if (el) el.onclick = fn;
  };

  bind("addOwnerBtn", addOwner);
  bind("changeOwnerBtn", changeOwnerClub);
  bind("clubAuctionRegisterBtn", registerForClubAuction);
  bind("linkOwnerBtn", linkOwner);
  bind("breakOwnerBtn", () => removeFromClub({ addToWaitingList: false }));
  bind("breakOwnerWaitingBtn", () => removeFromClub({ addToWaitingList: true }));
  bind("archiveOwnerBtn", archiveOwner);
  bind("unarchiveOwnerBtn", unarchiveOwner);
  bind("updateEmailBtn", updateEmail);
  bind("setOwnerTagBtn", setOwnerTag);
  bind("setPasswordBtn", setOwnerPassword);
  bind("resetPasswordBtn", resetPassword);
  bind("refreshClubOwnersBtn", loadClubOwnersRemoveList);
  bind("removeAllWaitingBtn", () => bulkRemoveClubOwners({ addToWaitingList: true }));
  bind("removeAllOnlyBtn", () => bulkRemoveClubOwners({ addToWaitingList: false }));

  document.getElementById("tagOwnerSelect")?.addEventListener("change", syncOwnerTagInputFromSelect);
  document.getElementById("clubOwnerFilter")?.addEventListener("input", () =>
    renderClubOwnersRemoveList(window.__clubOwnersRemoveCache || [])
  );
  document.getElementById("archiveOwnerFilter")?.addEventListener("input", (e) => {
    filterArchiveOwnerSelect(e.target.value);
  });
  document.getElementById("unarchiveOwnerFilter")?.addEventListener("input", (e) => {
    filterUnarchiveOwnerSelect(e.target.value);
  });

  document.getElementById("wlRefreshBtn")?.addEventListener("click", loadWaitingListAdmin);
  document.getElementById("wlRestoreOrderBtn")?.addEventListener("click", restoreWaitingListOrder);
  document.getElementById("wlBoardFilter")?.addEventListener("input", (e) => {
    filterSeasonOwnerBoard(e.target.value);
  });
  document.getElementById("wlArchivedFilter")?.addEventListener("input", (e) => {
    filterArchivedOwnersBoard(e.target.value);
  });
  document.getElementById("wlAssignClubCancel")?.addEventListener("click", closeAssignClubModal);
  document.getElementById("wlAssignClubConfirm")?.addEventListener("click", confirmAssignClubModal);
  document.getElementById("wlAssignClubModal")?.addEventListener("click", (e) => {
    if (e.target?.id === "wlAssignClubModal") closeAssignClubModal();
  });

  if (needsWaitingList) await loadWaitingListAdmin();
  if (
    location.hash === "#owner-last-login" ||
    location.hash === "#season-owner-board"
  ) {
    document.getElementById("season-owner-board")?.scrollIntoView({ behavior: "smooth" });
  }
  if (needsClubOwnerRemove) await loadClubOwnersRemoveList();
});

async function loadOwnerList() {
  const dropdown = document.getElementById("updateOwnerSelect");
  const tagDropdown = document.getElementById("tagOwnerSelect");
  const archiveDropdown = document.getElementById("archiveOwnerSelect");
  const unarchiveDropdown = document.getElementById("unarchiveOwnerSelect");

  const owners = await fetchAdminOwnerRows();
  if (!owners.length) {
    const errHtml = `<option value="">Error loading owners</option>`;
    if (dropdown) dropdown.innerHTML = errHtml;
    if (tagDropdown) tagDropdown.innerHTML = errHtml;
    if (archiveDropdown) archiveDropdown.innerHTML = errHtml;
    if (unarchiveDropdown) unarchiveDropdown.innerHTML = errHtml;
    return;
  }

  if (dropdown) dropdown.innerHTML = "";
  if (tagDropdown) tagDropdown.innerHTML = "";
  if (archiveDropdown) {
    archiveDropdown.innerHTML = `<option value="">Select owner…</option>`;
  }
  if (unarchiveDropdown) {
    unarchiveDropdown.innerHTML = `<option value="">Select archived owner…</option>`;
  }

  const archiveOptions = [];
  const unarchiveOptions = [];

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

    const entry = {
      email: row.email,
      ownerId: row.id,
      label: formatTagOptionLabel(shortName, row.email, currentTag),
      tag: currentTag,
      shortName,
    };

    if (archiveDropdown && row.registryStatus !== "archived") {
      archiveOptions.push(entry);
    }
    if (unarchiveDropdown && row.registryStatus === "archived") {
      unarchiveOptions.push(entry);
    }
  });

  if (archiveDropdown) {
    window.__archiveOwnerOptionsCache = archiveOptions;
    filterArchiveOwnerSelect(document.getElementById("archiveOwnerFilter")?.value || "");
  }
  if (unarchiveDropdown) {
    window.__unarchiveOwnerOptionsCache = unarchiveOptions;
    filterUnarchiveOwnerSelect(document.getElementById("unarchiveOwnerFilter")?.value || "");
  }

  await syncOwnerTagInputFromSelect();
}

function filterOwnerSelectDropdown(dropdownId, cacheKey, filterText, emptyLabel) {
  const dropdown = document.getElementById(dropdownId);
  if (!dropdown) return;

  const cache = window[cacheKey] || [];
  const q = String(filterText || "")
    .trim()
    .toLowerCase();
  const prev = dropdown.value;

  const matches = !q
    ? cache
    : cache.filter((row) => {
        const hay = [row.label, row.tag, row.email, row.shortName]
          .map((x) => String(x || "").toLowerCase())
          .join(" ");
        return hay.includes(q);
      });

  dropdown.innerHTML = "";
  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.textContent = matches.length
    ? q
      ? `${emptyLabel} (${matches.length} match${matches.length === 1 ? "" : "es"})`
      : emptyLabel
    : "No matching owners";
  dropdown.appendChild(placeholder);

  for (const row of matches) {
    const opt = document.createElement("option");
    opt.value = row.email;
    opt.dataset.ownerId = row.ownerId;
    opt.textContent = row.label;
    dropdown.appendChild(opt);
  }

  if (prev && matches.some((r) => r.email === prev)) {
    dropdown.value = prev;
  }
}

function filterArchiveOwnerSelect(filterText) {
  filterOwnerSelectDropdown(
    "archiveOwnerSelect",
    "__archiveOwnerOptionsCache",
    filterText,
    "Select owner…"
  );
}

function filterUnarchiveOwnerSelect(filterText) {
  filterOwnerSelectDropdown(
    "unarchiveOwnerSelect",
    "__unarchiveOwnerOptionsCache",
    filterText,
    "Select archived owner…"
  );
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
  const discordTag = document.getElementById("ownerDiscordTag")?.value?.trim() || "";

  if (!email || !password || !club) {
    setStatus("ownerStatus", "Fill email, password, and club ShortName.", false);
    return;
  }
  if (!discordTag) {
    setStatus(
      "ownerStatus",
      "Enter their Discord tag / display name (shown on Discord NEW OWNER news).",
      false
    );
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

  // Save Discord tag before club link so the Discord news trigger can read it
  setStatus("ownerStatus", "Saving Discord tag…");
  const { error: tagErr } = await supabase.rpc("admin_owner_set_tag", {
    p_owner_email: email,
    p_tag: discordTag,
  });
  if (tagErr) {
    setStatus(
      "ownerStatus",
      `⚠️ Login created, but Discord tag failed: ${tagErr.message}. Set tag, then link club.`,
      false
    );
    await loadOwnerList();
    return;
  }

  setStatus("ownerStatus", "Login created — linking club…");
  const { data, error: linkErr } = await supabase.rpc("admin_assign_club_owner", {
    p_owner_email: email,
    p_club_short_name: club,
    p_owner_tag: discordTag,
  });

  if (linkErr) {
    // Fallback if 3-arg RPC not deployed yet
    const { data: data2, error: linkErr2 } = await supabase.rpc("admin_assign_club_owner", {
      p_owner_email: email,
      p_club_short_name: club,
    });
    if (linkErr2) {
      setStatus(
        "ownerStatus",
        `⚠️ Login + tag saved for ${email}, but club link failed: ${linkErr2.message}. Use Link existing login.`,
        false
      );
      await loadOwnerList();
      return;
    }
    setStatus(
      "ownerStatus",
      `✅ ${discordTag} created and linked to ${data2?.club_name || club}.`,
      true
    );
    await loadOwnerList();
    return;
  }

  setStatus(
    "ownerStatus",
    `✅ ${data?.owner_tag || discordTag} created and linked to ${data?.club_name || club}.`,
    true
  );
  await loadOwnerList();
}

async function removeFromClub({
  addToWaitingList = false,
  email: emailArg = null,
  ownerId = null,
  label = null,
  skipConfirm = false,
  statusId = "breakOwnerStatus",
} = {}) {
  const email =
    emailArg || document.getElementById("breakOwnerEmail")?.value?.trim() || null;
  const statusEl =
    document.getElementById(statusId) ? statusId : "breakOwnerStatus";
  if (!email && !ownerId) {
    setStatus(statusEl, "Enter owner email or pick someone from the list.", false);
    return false;
  }

  const who = label || email || ownerId;
  const waitBit = addToWaitingList
    ? "They will be added to the waiting list as a returning member."
    : "They will NOT be added to the waiting list (club/nation cleared only).";

  if (
    !skipConfirm &&
    !confirm(
      `Remove ${who} from their club?\n\n${waitBit}\nHistory is kept.`
    )
  ) {
    return false;
  }

  setStatus(statusEl, "Removing…");
  const payload = {
    p_add_to_waiting_list: !!addToWaitingList,
  };
  if (ownerId) payload.p_owner_id = ownerId;
  if (email) payload.p_owner_email = email;

  const { data, error } = await supabase.rpc("admin_owner_remove_from_club", payload);
  if (error) {
    setStatus(
      statusEl,
      `❌ ${error.message}${
        /admin_owner_remove_from_club|schema cache|Could not find/i.test(error.message || "")
          ? " — run supabase/sql/patches/admin_owners_remove_list.sql"
          : ""
      }`,
      false
    );
    return false;
  }

  const waiting =
    data?.added_to_waiting_list === true
      ? " · added to waiting list"
      : " · not on waiting list";
  setStatus(
    statusEl,
    `✅ ${data?.owner_tag || email || who} removed from ${
      data?.club_name || data?.club_short_name || "club"
    }${data?.nation_code ? ` · nation ${data.nation_code} released` : ""}${waiting}`,
    true
  );

  if (document.getElementById("clubOwnersTableWrap")) {
    await loadClubOwnersRemoveList();
  }
  if (
    document.getElementById("updateOwnerSelect") ||
    document.getElementById("tagOwnerSelect") ||
    document.getElementById("archiveOwnerSelect") ||
    document.getElementById("unarchiveOwnerSelect")
  ) {
    await loadOwnerList();
  }
  if (document.getElementById("wlAdminTableWrap")) {
    await loadWaitingListAdmin();
  }
  return true;
}

function escapeOwnerHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadClubOwnersRemoveList() {
  const wrap = document.getElementById("clubOwnersTableWrap");
  if (!wrap) return;
  wrap.innerHTML = `<p class="note">Loading…</p>`;
  const owners = (await fetchAdminOwnerRows()).filter((r) => r.clubShortName);
  window.__clubOwnersRemoveCache = owners;
  renderClubOwnersRemoveList(owners);
}

function renderClubOwnersRemoveList(owners) {
  const wrap = document.getElementById("clubOwnersTableWrap");
  if (!wrap) return;

  const q = String(document.getElementById("clubOwnerFilter")?.value || "")
    .trim()
    .toLowerCase();
  const rows = (owners || []).filter((r) => {
    if (!q) return true;
    const hay = `${r.clubShortName || ""} ${r.ownerTag || ""} ${r.email || ""}`.toLowerCase();
    return hay.includes(q);
  });

  if (!owners?.length) {
    wrap.innerHTML = `<p class="note">No owners currently linked to a club.</p>`;
    return;
  }
  if (!rows.length) {
    wrap.innerHTML = `<p class="note">No owners match the filter.</p>`;
    return;
  }

  wrap.innerHTML = `
    <table class="owner-remove-table">
      <thead>
        <tr>
          <th>Club</th>
          <th>Tag</th>
          <th>Email</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((r) => {
            const label = escapeOwnerHtml(
              `${r.ownerTag || "—"} (${r.clubShortName})`
            );
            return `
          <tr>
            <td><code>${escapeOwnerHtml(r.clubShortName)}</code></td>
            <td>${escapeOwnerHtml(r.ownerTag || "—")}</td>
            <td>${escapeOwnerHtml(r.email || "—")}</td>
            <td>
              <div class="actions">
                <button type="button" class="button secondary remove-only-btn"
                  data-owner-id="${escapeOwnerHtml(r.id)}"
                  data-email="${escapeOwnerHtml(r.email || "")}"
                  data-label="${label}">Remove from club</button>
                <button type="button" class="button remove-waiting-btn"
                  data-owner-id="${escapeOwnerHtml(r.id)}"
                  data-email="${escapeOwnerHtml(r.email || "")}"
                  data-label="${label}">Remove + waiting list</button>
              </div>
            </td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>
    <p class="note">${rows.length} owner${rows.length === 1 ? "" : "s"} shown.</p>`;

  wrap.querySelectorAll(".remove-only-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try {
        await removeFromClub({
          addToWaitingList: false,
          ownerId: btn.dataset.ownerId,
          email: btn.dataset.email || null,
          label: btn.dataset.label,
        });
      } finally {
        btn.disabled = false;
      }
    });
  });
  wrap.querySelectorAll(".remove-waiting-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try {
        await removeFromClub({
          addToWaitingList: true,
          ownerId: btn.dataset.ownerId,
          email: btn.dataset.email || null,
          label: btn.dataset.label,
        });
      } finally {
        btn.disabled = false;
      }
    });
  });
}

async function bulkRemoveClubOwners({ addToWaitingList }) {
  const owners = (window.__clubOwnersRemoveCache || []).filter((r) => r.clubShortName);
  if (!owners.length) {
    setStatus("breakOwnerStatus", "No club owners to remove.", false);
    return;
  }

  const mode = addToWaitingList
    ? "remove + waiting list"
    : "remove only (no waiting list)";
  if (
    !confirm(
      `Remove ALL ${owners.length} club owner${owners.length === 1 ? "" : "s"}?\n\nMode: ${mode}.\nThis cannot be undone from this screen.`
    )
  ) {
    return;
  }

  setStatus("breakOwnerStatus", `Removing ${owners.length}…`);
  let ok = 0;
  let fail = 0;
  let lastErr = "";
  for (const r of owners) {
    const payload = {
      p_add_to_waiting_list: !!addToWaitingList,
      p_owner_id: r.id,
    };
    if (r.email) payload.p_owner_email = r.email;
    const { error } = await supabase.rpc("admin_owner_remove_from_club", payload);
    if (error) {
      fail += 1;
      lastErr = error.message;
    } else {
      ok += 1;
    }
  }
  setStatus(
    "breakOwnerStatus",
    `✅ Bulk done — ${ok} removed${fail ? `, ${fail} failed (${lastErr})` : ""}${
      addToWaitingList ? " (remove + waiting list)" : " (remove only)"
    }.`,
    fail === 0
  );
  await loadClubOwnersRemoveList();
}

async function archiveOwner() {
  const select = document.getElementById("archiveOwnerSelect");
  const email =
    select?.value?.trim() ||
    document.getElementById("archiveOwnerEmail")?.value?.trim() ||
    "";
  const note = document.getElementById("archiveOwnerNote")?.value?.trim() || null;
  const label = select?.selectedOptions?.[0]?.textContent?.trim() || email;
  if (!email || email.includes("Error")) {
    setStatus("archiveOwnerStatus", "Select an owner.", false);
    return;
  }
  if (
    !confirm(
      `Archive ${label}?\n\nThey will be archived (detached from any club/nation and removed from the waiting list). Unarchive before linking a club again.`
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
  const wasClub = data?.club_short_name || (data?.had_club === false ? "no club" : "club");
  setStatus(
    "archiveOwnerStatus",
    `✅ Archived ${data?.owner_tag || email} (was ${wasClub})`,
    true
  );
  if (document.getElementById("archiveOwnerNote")) {
    document.getElementById("archiveOwnerNote").value = "";
  }
  await loadOwnerList();
}

async function unarchiveOwner() {
  const select = document.getElementById("unarchiveOwnerSelect");
  const email =
    select?.value?.trim() ||
    document.getElementById("unarchiveOwnerEmail")?.value?.trim() ||
    "";
  const label = select?.selectedOptions?.[0]?.textContent?.trim() || email;
  if (!email || email.includes("Error")) {
    setStatus("unarchiveOwnerStatus", "Select an archived owner.", false);
    return;
  }
  if (!confirm(`Unarchive ${label}?\n\nThey will return to the waiting list as a returning member.`)) {
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
    `✅ ${data?.owner_tag || data?.email || email} unarchived — on waiting list`,
    true
  );
  if (document.getElementById("unarchiveOwnerFilter")) {
    document.getElementById("unarchiveOwnerFilter").value = "";
  }
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
  const discordTag =
    document.getElementById("clubAuctionDiscordTag")?.value?.trim() || "";
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

  if (!discordTag) {
    setStatus(
      "clubAuctionStatus",
      "Enter their Discord tag / display name.",
      false
    );
    return;
  }

  setStatus("clubAuctionStatus", registerOnly ? "Registering existing account…" : "Creating owner…");

  const { data, error } = await invokeEdgeFunction("create-owner-club-auction", {
    email,
    password: registerOnly ? undefined : password,
    startingBalance: clubAuctionStartingBalance,
    registerOnly,
    ownerTag: discordTag,
  });

  if (error) {
    const hint =
      error.message?.includes("404") || error.message?.includes("not found")
        ? " — deploy create-owner-club-auction edge function in Supabase"
        : "";
    setStatus("clubAuctionStatus", "❌ " + error.message + hint, false);
    return;
  }

  // Ensure tag is stored even if edge upsert skipped it
  const { error: tagErr } = await supabase.rpc("admin_owner_set_tag", {
    p_owner_email: email,
    p_tag: discordTag,
  });
  if (tagErr) {
    setStatus(
      "clubAuctionStatus",
      `⚠️ Account on waiting list, but Discord tag failed: ${tagErr.message}. Set tag under Owners.`,
      false
    );
    await loadOwnerList();
    return;
  }

  if (document.getElementById("clubAuctionEmail")) {
    document.getElementById("clubAuctionEmail").value = "";
  }
  if (document.getElementById("clubAuctionPassword")) {
    document.getElementById("clubAuctionPassword").value = "";
  }
  if (document.getElementById("clubAuctionDiscordTag")) {
    document.getElementById("clubAuctionDiscordTag").value = "";
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
    `✅ ${discordTag} (${email}) ${action} — added to the bottom of the waiting list. Share login details; they start at member_home.html.`,
    true
  );
  await loadOwnerList();
}

async function linkOwner() {
  const email = document.getElementById("linkOwnerEmail").value.trim();
  const club = document.getElementById("linkOwnerClub").value.trim();
  const discordTag = document.getElementById("linkOwnerDiscordTag")?.value?.trim() || "";

  if (!email || !club) {
    setStatus("linkOwnerStatus", "Enter email and club ShortName.", false);
    return;
  }
  if (!discordTag) {
    setStatus(
      "linkOwnerStatus",
      "Enter their Discord tag / display name for Discord news.",
      false
    );
    return;
  }

  setStatus("linkOwnerStatus", "Saving Discord tag…");
  const { error: tagErr } = await supabase.rpc("admin_owner_set_tag", {
    p_owner_email: email,
    p_tag: discordTag,
  });
  if (tagErr) {
    setStatus("linkOwnerStatus", "❌ " + tagErr.message, false);
    return;
  }

  setStatus("linkOwnerStatus", "Linking…");
  let data = null;
  let error = null;
  ({ data, error } = await supabase.rpc("admin_assign_club_owner", {
    p_owner_email: email,
    p_club_short_name: club,
    p_owner_tag: discordTag,
  }));
  if (error) {
    ({ data, error } = await supabase.rpc("admin_assign_club_owner", {
      p_owner_email: email,
      p_club_short_name: club,
    }));
  }

  if (error) {
    setStatus("linkOwnerStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "linkOwnerStatus",
    `✅ ${data?.club_name || club} → ${data?.owner_tag || discordTag} (${data?.email || email})`,
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

function formatWlTimeSince(iso, nowMs = Date.now()) {
  if (!iso) return { text: "Never", minutes: Number.POSITIVE_INFINITY };
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return { text: "—", minutes: Number.POSITIVE_INFINITY };
  let mins = Math.floor((nowMs - then) / 60000);
  if (mins < 0) mins = 0;
  const weeks = Math.floor(mins / (7 * 24 * 60));
  const days = Math.floor((mins % (7 * 24 * 60)) / (24 * 60));
  const hours = Math.floor((mins % (24 * 60)) / 60);
  const minutes = mins % 60;
  const parts = [];
  if (weeks) parts.push(`${weeks}w`);
  if (days) parts.push(`${days}d`);
  if (hours) parts.push(`${hours}h`);
  if (minutes || parts.length === 0) parts.push(`${minutes}m`);
  return { text: parts.join(" "), minutes: mins };
}

function formatWlUkDateTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function formatWlUkDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleDateString("en-GB", {
    timeZone: "Europe/London",
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

async function fetchOwnerActivityById() {
  const { data, error } = await supabase.rpc("admin_owner_last_logins");
  const byId = new Map();
  let previousLabel = "Prev month";
  let currentLabel = "Current month";
  if (error) {
    return { byId, previousLabel, currentLabel, error };
  }
  const owners = Array.isArray(data?.owners) ? data.owners : Array.isArray(data) ? data : [];
  previousLabel = data?.previous_gpsl_month_label || previousLabel;
  currentLabel = data?.current_gpsl_month_label || currentLabel;
  for (const row of owners) {
    if (row?.owner_id) byId.set(row.owner_id, row);
  }
  return { byId, previousLabel, currentLabel, error: null };
}

function filterSeasonOwnerBoard(filterText) {
  const wrap = document.getElementById("wlAdminTableWrap");
  if (!wrap) return;
  const q = String(filterText || "")
    .trim()
    .toLowerCase();
  wrap.querySelectorAll("tr[data-owner-id]").forEach((tr) => {
    if (!q) {
      tr.classList.remove("wl-filter-hide");
      return;
    }
    const hay = (tr.dataset.filterText || "").toLowerCase();
    tr.classList.toggle("wl-filter-hide", !hay.includes(q));
  });
}

async function loadWaitingListAdmin() {
  const tableWrap = document.getElementById("wlAdminTableWrap");
  if (!tableWrap) return;

  tableWrap.innerHTML = "<p class='note'>Loading…</p>";
  const [boardRes, activityRes] = await Promise.all([
    supabase.rpc("waiting_list_admin"),
    fetchOwnerActivityById(),
  ]);

  if (boardRes.error) {
    tableWrap.innerHTML = `<p class="note" style="color:#f88">❌ ${boardRes.error.message} — run waiting_list_priority_board_20260829.sql</p>`;
    await loadArchivedOwnersSection();
    return;
  }

  const data = boardRes.data;
  const activityById = activityRes.byId;
  const prevLabel = activityRes.previousLabel || "Prev month";
  const curLabel = activityRes.currentLabel || "Current month";

  const priority = (data?.priority || data?.waiting || []).map((r) => ({
    ...r,
    has_club: !!r.has_club || r.list_kind === "club_owner",
    invited_auction: false,
    activity: activityById.get(r.owner_id) || null,
  }));
  const invited = (data?.invited_to_auction || []).map((r) => ({
    ...r,
    position: null,
    tier: "—",
    invited_auction: true,
    has_club: false,
    activity: activityById.get(r.owner_id) || null,
  }));
  const rows = [...priority, ...invited];
  const ownerRows = priority.filter((r) => r.has_club);
  const waitingRows = priority.filter((r) => !r.has_club);
  const waitingCount = waitingRows.length + invited.length;
  const ownerCount = ownerRows.length;
  const auctionTotal = invited.length;
  const testTotal = rows.filter((r) => !!r.confirmed_test_season).length;
  const liveTotal = rows.filter((r) => !!r.confirmed_live_season).length;
  const sortNote = data?.priority_uses_admin_sort
    ? "Manual priority order"
    : "Join-date order (drag to customise)";
  const activityNote = activityRes.error
    ? `Activity unavailable: ${activityRes.error.message}`
    : `${prevLabel} / ${curLabel} logins · unplayed fixtures (prev / cur / season)`;

  const colSpan = 19;
  const sectionRow = (label) =>
    `<tr class="wl-section"><td colspan="${colSpan}" style="padding:10px 10px;color:#ccc;font-size:13px;font-weight:600;border-bottom:1px solid #444;border-top:1px solid #333;background:#161616">${label}</td></tr>`;

  let html =
    `<table class="admin-table wl-board-table">` +
    `<thead>` +
    `<tr class="wl-group-row">` +
    `<th colspan="6" class="wl-group-owner">Owner</th>` +
    `<th colspan="3" class="wl-group-season">Season</th>` +
    `<th colspan="9" class="wl-group-activity">Activity</th>` +
    `<th colspan="1" class="wl-group-actions">Actions</th>` +
    `</tr>` +
    `<tr>` +
    `<th class="wl-col-owner" style="width:2em"></th>` +
    `<th>#</th><th>Tag</th><th>Email</th><th>Tier</th><th>Status</th>` +
    `<th class="wl-col-season" title="Invite to / remove from club draft auction" style="text-align:center;line-height:1.25">Auction<br><span id="wlAuctionTotal" style="color:#ff9900">${auctionTotal}</span><span style="color:#888;font-weight:normal"> invited</span></th>` +
    `<th title="Confirmed for test season" style="text-align:center;line-height:1.25">Test<br><span id="wlTestTotal" style="color:#ff9900">${testTotal}</span><span style="color:#888;font-weight:normal"> / ${rows.length}</span></th>` +
    `<th title="Confirmed for live season" style="text-align:center;line-height:1.25">Live<br><span id="wlLiveTotal" style="color:#ff9900">${liveTotal}</span><span style="color:#888;font-weight:normal"> / ${rows.length}</span></th>` +
    `<th class="wl-col-activity wl-col-login">Last login</th>` +
    `<th class="num wl-num-login">Since</th>` +
    `<th class="num wl-num-login" title="Total GPSL site logins (all time)">Logins</th>` +
    `<th class="num wl-num-login" title="${escapeWl(prevLabel)} logins">${escapeWl(prevLabel)}</th>` +
    `<th class="num wl-num-login" title="${escapeWl(curLabel)} logins">${escapeWl(curLabel)}</th>` +
    `<th class="num wl-num-unplayed" title="Unplayed fixtures in ${escapeWl(prevLabel)} (league + cups)">U ${escapeWl(prevLabel)}</th>` +
    `<th class="num wl-num-unplayed" title="Unplayed fixtures in ${escapeWl(curLabel)} (league + cups)">U ${escapeWl(curLabel)}</th>` +
    `<th class="num wl-num-unplayed" title="Unplayed fixtures this season (all months, league + cups)">U season</th>` +
    `<th title="Discord server join date when known (self-serve Discord join). Otherwise account created (muted).">Discord</th>` +
    `<th class="wl-col-actions">Actions</th>` +
    `</tr></thead><tbody id="wlPriorityTbody">`;

  html += sectionRow(
    `Owners (${ownerCount}) — current club owners. Drag handle sets season priority with the waiting list. ${escapeWl(activityNote)}.`
  );
  if (!ownerCount) {
    html += `<tr><td colspan="${colSpan}" class="muted" style="padding:8px 10px">No club owners on the board.</td></tr>`;
  } else {
    for (const row of ownerRows) {
      html += renderWaitingListAdminRow(row, { invited: false, section: "owners" });
    }
  }

  html += sectionRow(
    `Waiting list (${waitingCount}` +
      (auctionTotal ? `; ${auctionTotal} invited to auction` : "") +
      `) — ${escapeWl(sortNote)}. Actions: Add club, absence, or Remove (→ archived).`
  );
  if (!waitingRows.length && !auctionTotal) {
    html += `<tr><td colspan="${colSpan}" class="muted" style="padding:8px 10px">No one on the waiting list.</td></tr>`;
  } else {
    for (const row of waitingRows) {
      html += renderWaitingListAdminRow(row, { invited: false, section: "waiting" });
    }
    for (const row of invited) {
      html += renderWaitingListAdminRow(row, { invited: true, section: "waiting" });
    }
  }

  html += "</tbody></table>";
  tableWrap.innerHTML = html;

  const filterEl = document.getElementById("wlBoardFilter");
  if (filterEl?.value) filterSeasonOwnerBoard(filterEl.value);

  bindWaitingListPriorityDrag(tableWrap);
  bindWlRowActionSelects(tableWrap);
  tableWrap.querySelectorAll(".wl-confirm-season").forEach((cb) => {
    cb.addEventListener("pointerdown", (e) => e.stopPropagation());
    cb.addEventListener("click", (e) => e.stopPropagation());
    cb.addEventListener("change", () =>
      setWaitingListSeasonConfirmed(cb.dataset.id, cb.dataset.which, cb.checked, cb)
    );
  });
  tableWrap.querySelectorAll(".wl-auction-invite").forEach((cb) => {
    cb.addEventListener("pointerdown", (e) => e.stopPropagation());
    cb.addEventListener("click", (e) => e.stopPropagation());
    cb.addEventListener("change", () =>
      setWaitingListAuctionInvite(cb.dataset.id, cb.checked, cb)
    );
  });

  await loadArchivedOwnersSection();
}

function bindWlRowActionSelects(root) {
  if (!root) return;
  root.querySelectorAll("select.wl-row-action").forEach((sel) => {
    sel.addEventListener("pointerdown", (e) => e.stopPropagation());
    sel.addEventListener("click", (e) => e.stopPropagation());
    sel.addEventListener("change", async () => {
      const action = sel.value;
      if (!action) return;
      const payload = {
        ownerId: sel.dataset.id || null,
        email: sel.dataset.email || null,
        tag: sel.dataset.tag || "",
        club: sel.dataset.club || "",
        select: sel,
      };
      sel.value = "";
      await runWlRowAction(action, payload);
    });
  });
}

async function runWlRowAction(action, { ownerId, email, tag, club, select }) {
  const label = [tag, club ? `(${club})` : "", email].filter(Boolean).join(" ");
  if (action === "remove_waiting") {
    await removeFromWaitingList({ ownerId, email, tag });
    return;
  }
  if (action === "add_club") {
    await assignClubFromWaitingRow({ email, tag });
    return;
  }
  if (action === "absence_on") {
    await setWaitingListAbsence(true, { email, tag });
    return;
  }
  if (action === "absence_off") {
    await setWaitingListAbsence(false, { email, tag });
    return;
  }
  if (action === "remove_club") {
    await removeFromClub({
      addToWaitingList: false,
      ownerId,
      email,
      label,
      statusId: "wlActionStatus",
    });
    return;
  }
  if (action === "to_waiting") {
    await removeFromClub({
      addToWaitingList: true,
      ownerId,
      email,
      label,
      statusId: "wlActionStatus",
    });
    return;
  }
  if (action === "unarchive") {
    await unarchiveOwnerFromBoard({ email, tag });
    return;
  }
  if (action === "delete_gpsl") {
    await deleteArchivedOwner({
      ownerId,
      email,
      tag,
      button: select,
    });
  }
}

let wlAssignClubPending = null;

async function assignClubFromWaitingRow({ email, tag }) {
  const who = tag || email || "this member";
  if (!email) {
    setWlActionStatus("Missing email for club assign.", false);
    return;
  }

  const modal = document.getElementById("wlAssignClubModal");
  const select = document.getElementById("wlAssignClubSelect");
  const whoEl = document.getElementById("wlAssignClubWho");
  const tagInput = document.getElementById("wlAssignClubTag");

  if (!modal || !select) {
    // Fallback if modal markup missing (other admin pages).
    const club = window.prompt(`Assign club to ${who}.\n\nEnter club ShortName:`, "")?.trim();
    if (!club) return;
    await finishAssignClubToWaitingMember({ email, tag: who, club, discordTag: "" });
    return;
  }

  wlAssignClubPending = { email, tag: who };
  if (whoEl) whoEl.textContent = `Assign a vacant club to ${who} (${email}).`;
  if (tagInput) tagInput.value = "";
  select.innerHTML = `<option value="">Loading vacant clubs…</option>`;
  modal.hidden = false;

  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .is("owner_id", null)
    .order("Club");

  if (error) {
    select.innerHTML = `<option value="">Could not load clubs</option>`;
    setWlActionStatus("❌ " + error.message, false);
    return;
  }

  const clubs = data || [];
  if (!clubs.length) {
    select.innerHTML = `<option value="">No vacant clubs available</option>`;
    return;
  }

  select.innerHTML =
    `<option value="">Select club…</option>` +
    clubs
      .map((c) => {
        const full = c.Club || c.ShortName;
        const short = c.ShortName || "";
        return `<option value="${escapeWl(short)}">${escapeWl(full)} (${escapeWl(short)})</option>`;
      })
      .join("");
}

function closeAssignClubModal() {
  const modal = document.getElementById("wlAssignClubModal");
  if (modal) modal.hidden = true;
  wlAssignClubPending = null;
}

async function confirmAssignClubModal() {
  const pending = wlAssignClubPending;
  const select = document.getElementById("wlAssignClubSelect");
  const club = select?.value?.trim();
  const clubLabel =
    select?.selectedOptions?.[0]?.textContent?.trim() || club?.toUpperCase() || club;
  const discordTag = document.getElementById("wlAssignClubTag")?.value?.trim() || "";
  if (!pending?.email) {
    closeAssignClubModal();
    return;
  }
  if (!club) {
    setWlActionStatus("Select a vacant club.", false);
    return;
  }
  closeAssignClubModal();
  await finishAssignClubToWaitingMember({
    email: pending.email,
    tag: pending.tag,
    club,
    clubLabel,
    discordTag,
  });
}

async function finishAssignClubToWaitingMember({ email, tag, club, clubLabel, discordTag }) {
  const who = tag || email;
  if (discordTag) {
    setWlActionStatus("Saving Discord tag…");
    const { error: tagErr } = await supabase.rpc("admin_owner_set_tag", {
      p_owner_email: email,
      p_tag: discordTag,
    });
    if (tagErr) {
      setWlActionStatus("❌ " + tagErr.message, false);
      return;
    }
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
  setWlActionStatus(
    `✅ ${who} assigned to ${clubLabel || club.toUpperCase()}.`,
    true
  );
}

async function unarchiveOwnerFromBoard({ email, tag }) {
  const who = tag || email || "this owner";
  if (!email) {
    setWlActionStatus("Missing email to unarchive.", false);
    return;
  }
  if (
    !confirm(
      `Unarchive ${who}?\n\nThey will return to the waiting list as a returning member.`
    )
  ) {
    return;
  }
  setWlActionStatus("Unarchiving…");
  const { data, error } = await supabase.rpc("admin_owner_unarchive", {
    p_owner_email: email,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  await loadOwnerList();
  setWlActionStatus(
    `✅ ${data?.owner_tag || data?.email || who} unarchived — on waiting list`,
    true
  );
}

function filterArchivedOwnersBoard(filterText) {
  const wrap = document.getElementById("wlArchivedTableWrap");
  if (!wrap) return;
  const q = String(filterText || "")
    .trim()
    .toLowerCase();
  wrap.querySelectorAll("tr[data-owner-id]").forEach((tr) => {
    if (!q) {
      tr.classList.remove("wl-filter-hide");
      return;
    }
    const hay = (tr.dataset.filterText || "").toLowerCase();
    tr.classList.toggle("wl-filter-hide", !hay.includes(q));
  });
}

async function loadArchivedOwnersSection() {
  const section = document.getElementById("wlArchivedSection");
  const wrap = document.getElementById("wlArchivedTableWrap");
  if (!section || !wrap) return;

  const { data, error } = await supabase.rpc("admin_list_archived_owners");
  if (error) {
    section.hidden = false;
    wrap.innerHTML = `<p class="note" style="color:#f88">❌ ${escapeWl(
      error.message
    )} — run admin_archived_owners_delete_20260901.sql</p>`;
    return;
  }

  const rows = Array.isArray(data?.archived) ? data.archived : [];
  if (!rows.length) {
    section.hidden = false;
    wrap.innerHTML = `<p class="note">No archived owners.</p>`;
    return;
  }

  section.hidden = false;
  let html =
    `<table class="admin-table wl-archived-table">` +
    `<thead><tr>` +
    `<th>Tag</th><th>Email</th><th>Last club</th><th>Archived (UK)</th><th>Note</th>` +
    `<th class="wl-col-actions">Actions</th>` +
    `</tr></thead><tbody>`;

  for (const row of rows) {
    const email = row.email || "";
    const tag = row.owner_tag || "—";
    const filterText = [tag, email, row.last_club_short_name, row.status_note]
      .filter(Boolean)
      .join(" ");
    html += `<tr data-owner-id="${escapeWl(row.owner_id)}" data-filter-text="${escapeWl(filterText)}">
      <td>${escapeWl(tag)}</td>
      <td>${escapeWl(email)}</td>
      <td>${escapeWl(row.last_club_short_name || "—")}</td>
      <td>${escapeWl(formatWlUkDateTime(row.status_changed_at))}</td>
      <td>${escapeWl(row.status_note || "—")}</td>
      <td class="wl-col-actions">
        <select class="wl-row-action"
          data-id="${escapeWl(row.owner_id)}"
          data-email="${escapeWl(email)}"
          data-tag="${escapeWl(tag)}"
          aria-label="Actions for ${escapeWl(tag)}">
          <option value="">Actions…</option>
          <option value="unarchive">Unarchive → waiting</option>
          <option value="delete_gpsl">Delete from GPSL</option>
        </select>
      </td>
    </tr>`;
  }
  html += `</tbody></table>`;
  wrap.innerHTML = html;

  const filterEl = document.getElementById("wlArchivedFilter");
  if (filterEl?.value) filterArchivedOwnersBoard(filterEl.value);

  bindWlRowActionSelects(wrap);
}

async function deleteArchivedOwner({ ownerId, email, tag, button }) {
  const label = [tag, email].filter(Boolean).join(" — ") || ownerId;
  if (
    !confirm(
      `Permanently delete ${label} from GPSL?\n\n` +
        `This removes their login and registry row. Only archived owners can be deleted.\n` +
        `This cannot be undone.`
    )
  ) {
    return;
  }

  if (button) button.disabled = true;
  setWlActionStatus(`Deleting ${label}…`);

  const { data, error } = await invokeEdgeFunction("delete-archived-owner", {
    ownerId,
  });

  if (error) {
    if (button) button.disabled = false;
    const hint = /Failed to send|FunctionsFetchError|not found|404/i.test(
      error.message || ""
    )
      ? " — deploy supabase/functions/delete-archived-owner and apply admin_archived_owners_delete_20260901.sql"
      : "";
    setWlActionStatus("❌ " + error.message + hint, false);
    return;
  }

  setWlActionStatus(
    `✅ Deleted ${data?.owner_tag || data?.email || label} from GPSL`,
    true
  );
  await loadArchivedOwnersSection();
  if (document.getElementById("archiveOwnerSelect") || document.getElementById("unarchiveOwnerSelect")) {
    await loadOwnerList();
  }
}

function renderWaitingListAdminRow(row, { invited, section = "waiting" }) {
  const email = row.email || "";
  const testOn = !!row.confirmed_test_season;
  const liveOn = !!row.confirmed_live_season;
  const hasClub = !!row.has_club && !invited;
  const pos = invited ? "—" : row.position;
  const act = row.activity || {};
  const clubFullName =
    row.club_name || act.club_name || row.club_short_name || act.club_short_name || "";
  let status = invited ? "awaiting_club_auction" : row.status || "";
  if (hasClub && clubFullName) {
    status = `owner · ${clubFullName}`;
  }
  const lastAt = act.last_sign_in_at || null;
  const since = formatWlTimeSince(lastAt);
  const sinceClass = !lastAt ? "never" : since.minutes >= 7 * 24 * 60 ? "stale" : "";
  const prevN = Number(act.logins_previous_month) || 0;
  const curN = Number(act.logins_current_month) || 0;
  const totalN = Number(act.logins_total) || 0;
  const unplayedPrev =
    act.unplayed_previous_month == null ? null : Number(act.unplayed_previous_month) || 0;
  const unplayedCur =
    act.unplayed_current_month == null ? null : Number(act.unplayed_current_month) || 0;
  const unplayedSeason =
    act.unplayed_season == null ? null : Number(act.unplayed_season) || 0;
  const formatUnplayed = (n) => {
    if (n == null) return `<span class="muted">—</span>`;
    const cls =
      n >= 3 ? "unplayed-bad" : n > 0 ? "unplayed-warn" : "";
    return `<span class="${cls}">${n}</span>`;
  };
  const discordJoined = act.discord_joined_at || null;
  const discordSource = act.discord_join_source || (discordJoined ? "discord" : "account");
  const discordDisplayAt =
    discordJoined || (discordSource === "account" ? act.account_created_at : null);
  const discordCell =
    discordSource === "discord" && discordJoined
      ? escapeWl(formatWlUkDate(discordJoined))
      : discordDisplayAt
        ? `<span class="muted" title="No Discord join on file — showing GPSL account created date">${escapeWl(formatWlUkDate(discordDisplayAt))} · acct</span>`
        : `<span class="muted" title="No Discord join recorded (admin-added or joined before Discord gate)">—</span>`;
  const filterText = [
    row.owner_tag,
    email,
    status,
    row.tier,
    row.club_short_name,
    clubFullName,
    act.club_short_name,
    act.club_name,
  ]
    .filter(Boolean)
    .join(" ");

  const rowClass = [
    invited ? "" : "wl-priority-row",
    hasClub ? "wl-club-owner" : "",
  ]
    .filter(Boolean)
    .join(" ");
  const rowStyle = invited ? ' style="background:#1a1814"' : "";
  const dragCell = invited
    ? `<td class="wl-col-owner"></td>`
    : `<td class="wl-col-owner wl-drag-cell" title="Drag to reorder"><span class="wl-drag-handle" aria-hidden="true">⠿</span></td>`;
  const auctionCell = hasClub
    ? `<td class="wl-col-season" style="text-align:center;color:#555" title="Already owns a club">—</td>`
    : `<td class="wl-col-season" style="text-align:center">
      <input type="checkbox" class="wl-auction-invite" data-id="${row.owner_id}"
        title="${invited ? "Remove from club auction (back to waiting list)" : "Invite to club auction"}"
        ${invited ? "checked" : ""}>
    </td>`;
  const actionSelect =
    section === "owners" || hasClub
      ? `<select class="wl-row-action" data-id="${row.owner_id}" data-email="${escapeWl(email)}" data-tag="${escapeWl(row.owner_tag || "")}" data-club="${escapeWl(row.club_short_name || "")}" aria-label="Actions">
        <option value="">Actions…</option>
        <option value="remove_club">Remove club</option>
        <option value="to_waiting">→ Waiting</option>
      </select>`
      : `<select class="wl-row-action" data-id="${row.owner_id}" data-email="${escapeWl(email)}" data-tag="${escapeWl(row.owner_tag || "")}" aria-label="Actions">
        <option value="">Actions…</option>
        <option value="add_club">Add club</option>
        <option value="absence_on">Mark on absence</option>
        <option value="absence_off">Clear absence</option>
        <option value="remove_waiting">Remove → archived</option>
      </select>`;

  return `<tr class="${rowClass}"${rowStyle} data-owner-id="${row.owner_id}" data-filter-text="${escapeWl(filterText)}">
    ${dragCell}
    <td class="wl-pos">${pos ?? "—"}</td>
    <td>${escapeWl(row.owner_tag)}</td>
    <td>${escapeWl(email)}</td>
    <td>${escapeWl(hasClub ? "—" : row.tier || "—")}</td>
    <td>${escapeWl(status)}</td>
    ${auctionCell}
    <td style="text-align:center">
      <input type="checkbox" class="wl-confirm-season" data-id="${row.owner_id}" data-which="test"
        title="Confirmed test season" ${testOn ? "checked" : ""}>
    </td>
    <td style="text-align:center">
      <input type="checkbox" class="wl-confirm-season" data-id="${row.owner_id}" data-which="live"
        title="Confirmed live season" ${liveOn ? "checked" : ""}>
    </td>
    <td class="wl-col-activity">${escapeWl(formatWlUkDateTime(lastAt))}</td>
    <td class="num wl-num-login ${sinceClass}">${escapeWl(since.text)}</td>
    <td class="num wl-num-login">${totalN}</td>
    <td class="num wl-num-login">${prevN}</td>
    <td class="num wl-num-login">${curN}</td>
    <td class="num wl-num-unplayed" title="Unplayed previous GPSL month">${formatUnplayed(unplayedPrev)}</td>
    <td class="num wl-num-unplayed" title="Unplayed current GPSL month">${formatUnplayed(unplayedCur)}</td>
    <td class="num wl-num-unplayed" title="Unplayed this season">${formatUnplayed(unplayedSeason)}</td>
    <td>${discordCell}</td>
    <td class="wl-col-actions">${actionSelect}</td>
  </tr>`;
}

function bindWaitingListPriorityDrag(tableWrap) {
  const tbody = tableWrap.querySelector("#wlPriorityTbody");
  if (!tbody) return;

  let dragRow = null;
  let startIds = null;
  let pointerId = null;

  const priorityRows = () => [...tbody.querySelectorAll("tr.wl-priority-row")];

  const priorityIds = () =>
    priorityRows()
      .map((tr) => tr.dataset.ownerId)
      .filter(Boolean);

  const renumberPositions = () => {
    let n = 0;
    priorityRows().forEach((tr) => {
      n += 1;
      const pos = tr.querySelector(".wl-pos");
      if (pos) pos.textContent = String(n);
    });
  };

  const rowFromY = (clientY) => {
    const rows = priorityRows();
    for (const tr of rows) {
      if (tr === dragRow) continue;
      const rect = tr.getBoundingClientRect();
      if (clientY < rect.top + rect.height / 2) return { tr, before: true };
      if (clientY <= rect.bottom) return { tr, before: false };
    }
    const last = rows.filter((r) => r !== dragRow).pop();
    return last ? { tr: last, before: false } : null;
  };

  const endDrag = async () => {
    if (!dragRow) return;
    const row = dragRow;
    row.classList.remove("wl-dragging");
    row.querySelectorAll("td").forEach((td) => {
      td.style.boxShadow = "";
    });
    dragRow = null;
    pointerId = null;

    const ids = priorityIds();
    if (!ids.length || !startIds) return;
    const changed = ids.length !== startIds.length || ids.some((id, i) => id !== startIds[i]);
    startIds = null;
    if (!changed) return;
    await saveWaitingListPriorityOrder(ids);
  };

  tbody.addEventListener("pointerdown", (e) => {
    if (e.button != null && e.button !== 0) return;
    // Never start a row-drag from controls — whole-row grab was eating checkbox clicks.
    if (e.target.closest("input,button,a,label,select,textarea")) {
      e.stopPropagation();
      return;
    }
    const handle = e.target.closest(".wl-drag-cell, .wl-drag-handle");
    if (!handle) return;
    const tr = handle.closest("tr.wl-priority-row");
    if (!tr) return;

    dragRow = tr;
    startIds = priorityIds();
    pointerId = e.pointerId;
    tr.classList.add("wl-dragging");
    try {
      tr.setPointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    e.preventDefault();
  });

  tbody.addEventListener("pointermove", (e) => {
    if (!dragRow || (pointerId != null && e.pointerId !== pointerId)) return;
    e.preventDefault();
    const hit = rowFromY(e.clientY);
    if (!hit) return;
    const { tr, before } = hit;
    const anchor = before ? tr : tr.nextSibling;
    if (dragRow === tr) return;
    if (before && dragRow.nextSibling === tr) return;
    if (!before && tr.nextSibling === dragRow) return;
    tbody.insertBefore(dragRow, anchor);
    renumberPositions();
  });

  tbody.addEventListener("pointerup", (e) => {
    if (pointerId != null && e.pointerId !== pointerId) return;
    endDrag();
  });

  tbody.addEventListener("pointercancel", (e) => {
    if (pointerId != null && e.pointerId !== pointerId) return;
    endDrag();
  });
}

async function saveWaitingListPriorityOrder(ownerIds) {
  setWlActionStatus("Saving order…");
  const { error } = await supabase.rpc("admin_waiting_list_reorder", {
    p_owner_ids: ownerIds,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    await loadWaitingListAdmin();
    return;
  }
  await loadWaitingListAdmin();
  setWlActionStatus("✅ Priority order saved.", true);
}

function escapeWl(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function refreshWaitingListConfirmTotals() {
  const wrap = document.getElementById("wlAdminTableWrap");
  if (!wrap) return;
  const testBoxes = [...wrap.querySelectorAll('.wl-confirm-season[data-which="test"]')];
  const liveBoxes = [...wrap.querySelectorAll('.wl-confirm-season[data-which="live"]')];
  const auctionBoxes = [...wrap.querySelectorAll(".wl-auction-invite")];
  const testEl = document.getElementById("wlTestTotal");
  const liveEl = document.getElementById("wlLiveTotal");
  const auctionEl = document.getElementById("wlAuctionTotal");
  if (testEl) testEl.textContent = String(testBoxes.filter((c) => c.checked).length);
  if (liveEl) liveEl.textContent = String(liveBoxes.filter((c) => c.checked).length);
  if (auctionEl) auctionEl.textContent = String(auctionBoxes.filter((c) => c.checked).length);
}

async function setWaitingListAuctionInvite(ownerId, invited, checkboxEl) {
  const { error } = await supabase.rpc("admin_waiting_list_set_auction_invite", {
    p_owner_id: ownerId,
    p_invited: !!invited,
    p_starting_balance: clubAuctionStartingBalance,
  });
  if (error) {
    if (checkboxEl) checkboxEl.checked = !invited;
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  await loadOwnerList();
  setWlActionStatus(
    invited
      ? "✅ Invited to club auction."
      : "✅ Removed from club auction — back on waiting list.",
    true
  );
}

async function setWaitingListSeasonConfirmed(ownerId, which, confirmed, checkboxEl) {
  const { error } = await supabase.rpc("admin_waiting_list_set_season_confirmed", {
    p_owner_id: ownerId,
    p_which: which,
    p_confirmed: !!confirmed,
  });
  if (error) {
    if (checkboxEl) checkboxEl.checked = !confirmed;
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  refreshWaitingListConfirmTotals();
  const label = which === "live" ? "live" : "test";
  setWlActionStatus(
    confirmed
      ? `✅ Marked confirmed for ${label} season.`
      : `✅ Cleared ${label} season confirmation.`,
    true
  );
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

async function directAssignFromWaitingList() {
  const email = wlActionEmail();
  const club = document.getElementById("wlAssignClub")?.value?.trim();
  let discordTag = document.getElementById("wlAssignDiscordTag")?.value?.trim() || "";
  if (!email || !club) {
    setWlActionStatus("Enter member email and club ShortName.", false);
    return;
  }
  if (!discordTag) {
    discordTag =
      window.prompt(
        "Discord tag / display name for NEW OWNER news (leave blank if already set):",
        ""
      )?.trim() || "";
  }
  if (discordTag) {
    setWlActionStatus("Saving Discord tag…");
    const { error: tagErr } = await supabase.rpc("admin_owner_set_tag", {
      p_owner_email: email,
      p_tag: discordTag,
    });
    if (tagErr) {
      setWlActionStatus("❌ " + tagErr.message, false);
      return;
    }
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

async function setWaitingListAbsence(on, { email = "", tag = "" } = {}) {
  const targetEmail = (email || wlActionEmail()).trim();
  if (!targetEmail) {
    setWlActionStatus("Enter member email, or use Actions on a waiting-list row.", false);
    return;
  }
  const who = tag || targetEmail;
  const note = on ? "Marked on absence by admin" : null;
  setWlActionStatus(on ? `Marking ${who} on absence…` : `Clearing absence for ${who}…`);
  const { error } = await supabase.rpc("admin_waiting_list_set_absence", {
    p_owner_email: targetEmail,
    p_on_absence: on,
    p_note: note,
  });
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  setWlActionStatus(
    on ? `✅ ${who} marked on absence.` : `✅ Absence cleared for ${who}.`,
    true
  );
}

async function removeFromWaitingList({ ownerId = null, email = "", tag = "" } = {}) {
  const label = tag || email || "this member";
  if (!ownerId && !email) {
    setWlActionStatus("Enter member email, or use Remove on a row.", false);
    return;
  }
  if (
    !confirm(
      `Remove ${label} from the waiting list?\n\nTheir login stays; they are archived and can be unarchived later.`
    )
  ) {
    return;
  }

  setWlActionStatus("Removing…");
  const payload = {};
  if (ownerId) payload.p_owner_id = ownerId;
  if (email) payload.p_owner_email = email;

  const { data, error } = await supabase.rpc("admin_waiting_list_remove", payload);
  if (error) {
    setWlActionStatus("❌ " + error.message, false);
    return;
  }
  await loadWaitingListAdmin();
  await loadOwnerList();
  setWlActionStatus(
    `✅ Removed ${data?.owner_tag || data?.email || label} from waiting list.`,
    true
  );
}
