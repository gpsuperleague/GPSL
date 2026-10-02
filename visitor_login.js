/** Discord visitor sign-in — read-only spectator sessions for GPSL Discord members. */
import { supabase } from "./supabase_client.js";

export const VISITOR_OAUTH_STATE = "gpsl_visitor";
export const VISITOR_HOME = "progress.html";

async function invokeFn(name, body) {
  const { data, error } = await supabase.functions.invoke(name, { body: body || {} });
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
    throw new Error(detail);
  }
  if (data?.error) throw new Error(String(data.error));
  return data;
}

/** Send the browser to Discord; it returns to join_gpsl.html with state=gpsl_visitor. */
export async function startVisitorDiscordLogin() {
  const cfg = await invokeFn("discord-join-config", {});
  if (!cfg?.client_id) throw new Error("Discord sign-in is not configured yet.");
  const params = new URLSearchParams({
    client_id: cfg.client_id,
    response_type: "code",
    redirect_uri: cfg.redirect_uri,
    scope: cfg.scopes || "identify",
    state: VISITOR_OAUTH_STATE,
  });
  window.location.assign(`https://discord.com/api/oauth2/authorize?${params.toString()}`);
}

/** Exchange the Discord code for a visitor session, then go to the visitor home page. */
export async function completeVisitorDiscordLogin(code) {
  const data = await invokeFn("discord-visitor-login", { code });
  if (!data?.token_hash) throw new Error("Visitor sign-in failed — no token returned.");
  const { error } = await supabase.auth.verifyOtp({
    token_hash: data.token_hash,
    type: "magiclink",
  });
  if (error) throw new Error(error.message || "Could not start the visitor session.");
  window.location.assign(VISITOR_HOME);
}
