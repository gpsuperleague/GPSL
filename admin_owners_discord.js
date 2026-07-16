import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

/** @type {Array<Record<string, unknown>>} */
let allMembers = [];
let clubAuctionStartingBalance = 600000000;
let openAddId = null;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatJoinedAt(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
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

async function loadClubAuctionConfig() {
  const { data } = await supabase.rpc("club_auction_get_config");
  if (data?.starting_balance > 0) {
    clubAuctionStartingBalance = Math.round(Number(data.starting_balance));
  }
}

function gpslStatusHtml(m) {
  if (m.awaiting_club_auction) {
    return `<span class="discord-status auction">Awaiting club auction</span>`;
  }
  if (m.on_waiting_list) {
    return `<span class="discord-status on-list">On waiting list</span>`;
  }
  if (m.gpsl_club) {
    return `<span class="discord-status active">Club ${escapeHtml(m.gpsl_club)}</span>`;
  }
  if (m.gpsl_status) {
    return `<span class="discord-status active">${escapeHtml(m.gpsl_status)}</span>`;
  }
  return `<span class="discord-status none">Not on GPSL</span>`;
}

function filteredMembers() {
  const q = (document.getElementById("discordSearch")?.value || "")
    .trim()
    .toLowerCase();
  const hideKnown = document.getElementById("discordHideKnown")?.checked === true;

  return allMembers.filter((m) => {
    if (hideKnown && (m.on_waiting_list || m.awaiting_club_auction || m.gpsl_club || m.gpsl_status)) {
      return false;
    }
    if (!q) return true;
    const hay = [
      m.display_name,
      m.username,
      m.global_name,
      m.nick,
      m.gpsl_club,
      m.gpsl_matched_tag,
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    return hay.includes(q);
  });
}

function renderTable() {
  const wrap = document.getElementById("discordTableWrap");
  if (!wrap) return;

  const rows = filteredMembers();
  if (!allMembers.length) {
    wrap.innerHTML = `<p class="note">No members loaded yet — click Refresh from Discord.</p>`;
    return;
  }

  if (!rows.length) {
    wrap.innerHTML = `<p class="note">No members match the filter.</p>`;
    return;
  }

  wrap.innerHTML = `
    <table class="discord-table">
      <thead>
        <tr>
          <th>#</th>
          <th>Member</th>
          <th>Joined Discord</th>
          <th>GPSL</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((m, idx) => {
            const id = String(m.discord_user_id);
            const avatar = m.avatar_url
              ? `<img class="discord-avatar" src="${escapeHtml(m.avatar_url)}" alt="">`
              : `<span class="discord-avatar" style="display:inline-block;"></span>`;
            const already =
              m.on_waiting_list || m.awaiting_club_auction || m.gpsl_club;
            const addOpen = openAddId === id;
            return `
          <tr data-discord-id="${escapeHtml(id)}">
            <td class="discord-meta">${idx + 1}</td>
            <td>
              ${avatar}
              <b>${escapeHtml(m.display_name)}</b>
              <div class="discord-meta">@${escapeHtml(m.username || "—")}</div>
            </td>
            <td>${escapeHtml(formatJoinedAt(m.joined_at))}</td>
            <td>${gpslStatusHtml(m)}</td>
            <td>
              ${
                already
                  ? `<span class="discord-meta">—</span>`
                  : `<button type="button" class="button secondary discord-add-btn" data-id="${escapeHtml(id)}">Add to waiting list</button>`
              }
              <div class="discord-add-panel${addOpen ? " open" : ""}" id="add-panel-${escapeHtml(id)}">
                <div class="row">
                  <input type="email" class="discord-email" data-id="${escapeHtml(id)}" placeholder="Owner email" autocomplete="off">
                  <input type="password" class="discord-password" data-id="${escapeHtml(id)}" placeholder="Temp password (min 6)" autocomplete="new-password">
                  <input type="text" class="discord-tag" data-id="${escapeHtml(id)}" value="${escapeHtml(m.username || m.display_name || "")}" placeholder="Owner tag">
                </div>
                <button type="button" class="button discord-confirm-add" data-id="${escapeHtml(id)}">Create &amp; add to list</button>
                <button type="button" class="button secondary discord-cancel-add" data-id="${escapeHtml(id)}">Cancel</button>
              </div>
            </td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>
  `;

  wrap.querySelectorAll(".discord-add-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      openAddId = btn.getAttribute("data-id");
      renderTable();
    });
  });
  wrap.querySelectorAll(".discord-cancel-add").forEach((btn) => {
    btn.addEventListener("click", () => {
      openAddId = null;
      renderTable();
    });
  });
  wrap.querySelectorAll(".discord-confirm-add").forEach((btn) => {
    btn.addEventListener("click", () => confirmAdd(btn.getAttribute("data-id")));
  });
}

async function loadMembers() {
  setStatus("discordStatus", "Loading Discord members…");
  const { data, error } = await invokeEdgeFunction("discord-guild-members", {});
  if (error) {
    const hint =
      error.message?.includes("404") || error.message?.includes("FunctionsFetchError")
        ? " — deploy discord-guild-members and set DISCORD_BOT_TOKEN + DISCORD_GUILD_ID secrets"
        : "";
    setStatus("discordStatus", "❌ " + error.message + hint, false);
    return;
  }

  allMembers = Array.isArray(data?.members) ? data.members : [];
  setStatus(
    "discordStatus",
    `✅ ${allMembers.length} member${allMembers.length === 1 ? "" : "s"} (oldest first)`,
    true
  );
  openAddId = null;
  renderTable();
}

async function confirmAdd(discordId) {
  const emailEl = document.querySelector(`.discord-email[data-id="${discordId}"]`);
  const passEl = document.querySelector(`.discord-password[data-id="${discordId}"]`);
  const tagEl = document.querySelector(`.discord-tag[data-id="${discordId}"]`);

  const email = emailEl?.value?.trim().toLowerCase() || "";
  const password = passEl?.value?.trim() || "";
  const ownerTag = tagEl?.value?.trim() || "";

  if (!email) {
    setStatus("discordStatus", "Enter owner email.", false);
    return;
  }
  if (password.length < 6) {
    setStatus("discordStatus", "Password must be at least 6 characters.", false);
    return;
  }

  setStatus("discordStatus", `Creating ${email} and adding to waiting list…`);

  const { data, error } = await invokeEdgeFunction("create-owner-club-auction", {
    email,
    password,
    startingBalance: clubAuctionStartingBalance,
    ownerTag: ownerTag || undefined,
  });

  if (error) {
    setStatus("discordStatus", "❌ " + error.message, false);
    return;
  }

  // Best-effort tag via RPC (upsert usually already set it)
  if (ownerTag) {
    await supabase.rpc("admin_owner_set_tag", {
      p_owner_email: email,
      p_tag: ownerTag,
    });
  }

  setStatus(
    "discordStatus",
    `✅ ${email} added to waiting list${ownerTag ? ` (tag ${ownerTag})` : ""}. Share login; invite from Waiting list when ready.`,
    true
  );
  openAddId = null;
  await loadMembers();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadClubAuctionConfig();

  document.getElementById("discordRefreshBtn")?.addEventListener("click", loadMembers);
  document.getElementById("discordSearch")?.addEventListener("input", renderTable);
  document.getElementById("discordHideKnown")?.addEventListener("change", renderTable);

  await loadMembers();
});
