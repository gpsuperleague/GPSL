import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";

const BUCKET = "player-cards";
const PESDB_CARD_BASE = "https://pesdb.net/assets/img/card";
const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function redirect(url: string, status = 302) {
  return new Response(null, {
    status,
    headers: {
      ...corsHeaders,
      Location: url,
      "Cache-Control": "public, max-age=3600",
    },
  });
}

function normalizeId(raw: unknown): string | null {
  const id = String(raw ?? "").trim();
  return /^\d{4,12}$/.test(id) ? id : null;
}

function storagePath(id: string) {
  return `${id}.png`;
}

function storagePublicUrl(id: string) {
  return `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${storagePath(id)}`;
}

function pesdbCardUrl(id: string) {
  return `${PESDB_CARD_BASE}/b${encodeURIComponent(id)}.png`;
}

async function publicObjectExists(url: string): Promise<boolean> {
  try {
    const res = await fetch(url, { method: "HEAD" });
    return res.ok;
  } catch {
    return false;
  }
}

async function cacheOneCard(admin: ReturnType<typeof createClient>, id: string) {
  const publicUrl = storagePublicUrl(id);
  if (await publicObjectExists(publicUrl)) {
    return { ok: true, cached: true, publicUrl, source: "storage" };
  }

  const upstreamUrl = pesdbCardUrl(id);
  const res = await fetch(upstreamUrl, {
    headers: { "User-Agent": USER_AGENT, Accept: "image/png,image/*;q=0.8,*/*;q=0.2" },
  });
  const contentType = String(res.headers.get("content-type") || "").toLowerCase();
  if (!res.ok || !contentType.startsWith("image/")) {
    return {
      ok: false,
      cached: false,
      publicUrl,
      source: "upstream-miss",
      status: res.status,
      contentType,
      upstreamUrl,
    };
  }

  const bytes = new Uint8Array(await res.arrayBuffer());
  const { error } = await admin.storage.from(BUCKET).upload(storagePath(id), bytes, {
    upsert: true,
    contentType: contentType || "image/png",
    cacheControl: "31536000",
  });
  if (error) {
    return {
      ok: false,
      cached: false,
      publicUrl,
      source: "storage-write-failed",
      error: error.message,
      upstreamUrl,
    };
  }

  return { ok: true, cached: false, publicUrl, source: "pesdb" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return jsonResponse({ error: "Server misconfigured" }, 500);
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    if (req.method === "GET") {
      const id = normalizeId(new URL(req.url).searchParams.get("id"));
      if (!id) return jsonResponse({ error: "Valid numeric id required" }, 400);

      const result = await cacheOneCard(admin, id);
      if (result.ok) return redirect(result.publicUrl);
      return redirect(result.upstreamUrl || pesdbCardUrl(id));
    }

    if (req.method === "POST") {
      if (!SUPABASE_ANON_KEY) {
        return jsonResponse({ error: "Server misconfigured" }, 500);
      }
      const authHeader = req.headers.get("Authorization");
      if (!authHeader) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
      const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
      });
      const {
        data: { user },
        error: userErr,
      } = await userClient.auth.getUser();
      if (userErr || !user) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
      const { data: isAdmin } = await userClient.rpc("is_gpsl_admin");
      if (isAdmin !== true) {
        return jsonResponse({ error: "Admin only" }, 403);
      }

      const body = (await req.json().catch(() => ({}))) as { ids?: unknown[] };
      const ids = Array.isArray(body.ids)
        ? [...new Set(body.ids.map(normalizeId).filter(Boolean) as string[])].slice(0, 200)
        : [];
      if (!ids.length) return jsonResponse({ error: "ids[] required" }, 400);

      const results = [];
      for (const id of ids) {
        results.push({ id, ...(await cacheOneCard(admin, id)) });
      }
      return jsonResponse({
        ok: true,
        requested: ids.length,
        cached_now: results.filter((r) => r.ok && r.source === "pesdb").length,
        already_cached: results.filter((r) => r.ok && r.source === "storage").length,
        failed: results.filter((r) => !r.ok).length,
        results,
      });
    }

    return jsonResponse({ error: "Method not allowed" }, 405);
  } catch (err) {
    return jsonResponse(
      { error: err instanceof Error ? err.message : String(err) },
      500,
    );
  }
});
