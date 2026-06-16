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
  document.getElementById("resetPasswordBtn").onclick = resetPassword;
});

async function loadOwnerList() {
  const dropdown = document.getElementById("updateOwnerSelect");
  const { data: ownerData, error: ownerError } =
    await supabase.functions.invoke("list-owners");

  if (ownerError || !ownerData?.users) {
    dropdown.innerHTML = `<option>Error loading owners</option>`;
    return;
  }

  const { data: clubs } = await supabase.from("Clubs").select("ShortName, owner_id");
  const { data: registry } = await supabase
    .from("gpsl_owner_registry")
    .select("owner_id, status, last_club_short_name");
  dropdown.innerHTML = "";

  const statusLabel = (ownerId, clubShort) => {
    const row = registry?.find((r) => r.owner_id === ownerId);
    if (clubShort) return clubShort;
    if (row?.status === "archived") return `ARCHIVED (${row.last_club_short_name || "?"})`;
    if (row?.status === "on_break") return `ON BREAK (${row.last_club_short_name || "?"})`;
    if (row?.status === "awaiting_club_auction") return "CLUB AUCTION";
    return "NO CLUB";
  };

  ownerData.users.forEach((u) => {
    const club = clubs?.find((c) => c.owner_id === u.id);
    const shortName = statusLabel(u.id, club?.ShortName);
    const option = document.createElement("option");
    option.value = u.id;
    option.textContent = `${shortName} — ${u.email}`;
    dropdown.appendChild(option);
  });
}

async function addOwner() {
  const email = document.getElementById("ownerEmail").value.trim();
  const password = document.getElementById("ownerPassword").value.trim();
  const club = document.getElementById("ownerClub").value.trim();

  if (!email || !password || !club) {
    setStatus("ownerStatus", "Fill all fields.", false);
    return;
  }

  setStatus("ownerStatus", "Creating…");
  const { error } = await supabase.functions.invoke("create-owner", {
    body: { email, password, clubShortName: club },
  });

  setStatus(
    "ownerStatus",
    error ? "❌ " + error.message : "✅ Owner created — setup email sent.",
    !error
  );
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
    `✅ ${email} ${action} — ${formatBudgetLabel(clubAuctionStartingBalance)} pending. Share the login details, then they open awaiting_club.html to set their tag.`,
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
