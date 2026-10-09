/* ============================================================
   SUPABASE — UNIFIED GLOBAL CLIENT + PASSWORD RESET HANDLER
   ============================================================ */

import { supabase } from "./supabase_client.js";

/* ============================================================
   PASSWORD RESET / MAGIC LINK HANDLER
   ============================================================ */

(async () => {
  const hash = window.location.hash;
  if (!hash) return;

  const params = new URLSearchParams(hash.replace("#", ""));

  const type = params.get("type");
  const access_token = params.get("access_token");
  const refresh_token = params.get("refresh_token");

  if (type === "recovery" && access_token && refresh_token) {
    await supabase.auth.setSession({
      access_token,
      refresh_token
    });

    window.location.href = "reset_password.html";
  }
})();

