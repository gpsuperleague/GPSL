import { initAdminPage, setStatus, supabase } from "./admin_common.js";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage("owners", "Owner administration"))) return;
  await loadOwnerList();

  document.getElementById("addOwnerBtn").onclick = addOwner;
  document.getElementById("linkOwnerBtn").onclick = linkOwner;
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
  dropdown.innerHTML = "";

  ownerData.users.forEach((u) => {
    const club = clubs?.find((c) => c.owner_id === u.id);
    const shortName = club ? club.ShortName : "NO CLUB";
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
