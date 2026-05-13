/* ============================================================
   SUPABASE — UNIFIED GLOBAL CLIENT + PASSWORD RESET HANDLER
   ============================================================ */

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const SUPABASE_URL = "https://omyyogfumrjoaweuawjn.supabase.co";
const SUPABASE_ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4";

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

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

/* ============================================================
   EXPOSE GLOBAL CLIENT
   ============================================================ */
window.supabase = supabase;
