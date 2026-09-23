import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { isGpslAdminOrMod } from "../_shared/gpsl_staff.ts";

const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const resendKey = Deno.env.get("RESEND_API_KEY");
    const fromEmail =
      Deno.env.get("GPSL_MAIL_FROM") || "GPSL <noreply@gpsuperleague.com>";

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return json({ error: "Server misconfigured" }, 500);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Unauthorized" }, 401);

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: userErr,
    } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "Unauthorized" }, 401);
    if (!(await isGpslAdminOrMod(userClient, user, GPSL_ADMIN_EMAIL))) {
      return json({ error: "Admin or mod only" }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const outboxId = Number(body?.outbox_id);
    if (!Number.isFinite(outboxId) || outboxId <= 0) {
      return json({ error: "outbox_id required" }, 400);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const { data: row, error: rowErr } = await admin
      .from("gpsl_email_outbox")
      .select("*")
      .eq("id", outboxId)
      .maybeSingle();
    if (rowErr) return json({ error: rowErr.message }, 500);
    if (!row) return json({ error: "Outbox row not found" }, 404);
    if (row.status === "sent") return json({ ok: true, already: true });

    if (!resendKey) {
      await admin
        .from("gpsl_email_outbox")
        .update({
          status: "skipped",
          error_text: "RESEND_API_KEY not configured",
        })
        .eq("id", outboxId);
      return json({
        ok: false,
        skipped: true,
        message: "RESEND_API_KEY not set — invite still active in inbox/Discord",
      });
    }

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: fromEmail,
        to: [row.to_email],
        subject: row.subject,
        html: row.html_body,
        text: row.text_body || undefined,
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      await admin
        .from("gpsl_email_outbox")
        .update({ status: "failed", error_text: errText.slice(0, 1000) })
        .eq("id", outboxId);
      return json({ error: "Resend failed", detail: errText.slice(0, 300) }, 502);
    }

    await admin
      .from("gpsl_email_outbox")
      .update({ status: "sent", sent_at: new Date().toISOString(), error_text: null })
      .eq("id", outboxId);

    return json({ ok: true });
  } catch (err) {
    return json({ error: String(err?.message || err) }, 500);
  }
});
