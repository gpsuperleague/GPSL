import { supabase } from "./supabase_client.js";

function setStatus(elId, msg, ok) {
  const el = document.getElementById(elId);
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("error", ok === false);
  el.classList.toggle("ok", ok === true);
}

function formatJoined(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

async function invokeJoin(name, body) {
  const { data, error } = await supabase.functions.invoke(name, {
    body: body || {},
  });
  if (error) {
    let detail = error.message || "Request failed";
    try {
      if (error.context && typeof error.context.json === "function") {
        const payload = await error.context.json();
        if (payload?.error) detail = String(payload.error);
      }
    } catch {
      /* ignore */
    }
    if (data?.error) detail = String(data.error);
    throw new Error(detail);
  }
  if (data?.error) throw new Error(String(data.error));
  return data;
}

function showForm(ticketPayload) {
  sessionStorage.setItem("gpsl_join_ticket", JSON.stringify(ticketPayload));
  document.getElementById("stepDiscord").hidden = true;
  document.getElementById("stepForm").hidden = false;
  document.getElementById("ownerTag").value = ticketPayload.suggested_tag || "";
  document.getElementById("discordMeta").textContent =
    `Discord @${ticketPayload.discord_username || ticketPayload.discord_user_id}` +
    ` · joined server ${formatJoined(ticketPayload.discord_joined_at)}`;
}

async function startDiscordOAuth() {
  setStatus("discordStatus", "Loading Discord…");
  const cfg = await invokeJoin("discord-join-config", {});
  if (!cfg?.client_id) throw new Error("Discord join is not configured yet.");

  const params = new URLSearchParams({
    client_id: cfg.client_id,
    response_type: "code",
    redirect_uri: cfg.redirect_uri,
    scope: cfg.scopes || "identify",
    prompt: "consent",
  });

  window.location.assign(
    `https://discord.com/api/oauth2/authorize?${params.toString()}`
  );
}

async function handleOAuthReturn() {
  const url = new URL(window.location.href);
  const code = url.searchParams.get("code");
  const err = url.searchParams.get("error");
  if (err) {
    setStatus(
      "discordStatus",
      `Discord authorization failed: ${err}`,
      false
    );
    return false;
  }
  if (!code) {
    const saved = sessionStorage.getItem("gpsl_join_ticket");
    if (saved) {
      try {
        const parsed = JSON.parse(saved);
        if (parsed?.ticket) {
          showForm(parsed);
          return true;
        }
      } catch {
        /* ignore */
      }
    }
    return false;
  }

  setStatus("discordStatus", "Checking Discord server membership…");
  try {
    const data = await invokeJoin("discord-join-callback", { code });
    url.searchParams.delete("code");
    url.searchParams.delete("state");
    history.replaceState({}, "", url.pathname + url.search + url.hash);

    showForm(data);
    setStatus("discordStatus", "", true);
    return true;
  } catch (e) {
    setStatus("discordStatus", e.message || String(e), false);
    url.searchParams.delete("code");
    history.replaceState({}, "", url.pathname);
    return false;
  }
}

async function createAccount() {
  const raw = sessionStorage.getItem("gpsl_join_ticket");
  if (!raw) {
    setStatus("formStatus", "Session expired — connect Discord again.", false);
    return;
  }
  let ticketPayload;
  try {
    ticketPayload = JSON.parse(raw);
  } catch {
    setStatus("formStatus", "Invalid session — connect Discord again.", false);
    return;
  }

  const ownerTag = document.getElementById("ownerTag").value.trim();
  const email = document.getElementById("email").value.trim();
  const password = document.getElementById("password").value;
  const password2 = document.getElementById("password2").value;
  const fairplayAccepted = document.getElementById("fairplayCheck").checked;

  if (!ownerTag) {
    setStatus("formStatus", "Owner tag is required.", false);
    return;
  }
  if (!email) {
    setStatus("formStatus", "Email is required.", false);
    return;
  }
  if (password.length < 6) {
    setStatus("formStatus", "Password must be at least 6 characters.", false);
    return;
  }
  if (password !== password2) {
    setStatus("formStatus", "Passwords do not match.", false);
    return;
  }
  if (!fairplayAccepted) {
    setStatus("formStatus", "You must accept the fair-play agreement.", false);
    return;
  }

  const btn = document.getElementById("createBtn");
  btn.disabled = true;
  setStatus("formStatus", "Creating account…");

  try {
    const data = await invokeJoin("discord-join-complete", {
      ticket: ticketPayload.ticket,
      email,
      password,
      ownerTag,
      fairplayAccepted: true,
    });
    sessionStorage.removeItem("gpsl_join_ticket");
    document.getElementById("stepForm").hidden = true;
    document.getElementById("stepDone").hidden = false;
    document.getElementById("doneMsg").textContent =
      data.message || "Account created. You are on the waiting list.";
  } catch (e) {
    setStatus("formStatus", e.message || String(e), false);
    btn.disabled = false;
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  document.getElementById("discordBtn")?.addEventListener("click", async () => {
    try {
      await startDiscordOAuth();
    } catch (e) {
      setStatus("discordStatus", e.message || String(e), false);
    }
  });
  document.getElementById("createBtn")?.addEventListener("click", createAccount);

  await handleOAuthReturn();
});
