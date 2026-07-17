import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const DISCORD_API = "https://discord.com/api/v10";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-feed-key",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type FeedRow = {
  id: number;
  event_type: string;
  headline: string;
  body: string | null;
  color: number | null;
  metadata: Record<string, unknown> | null;
};

type DiscordUser = {
  id: string;
  username?: string;
  global_name?: string | null;
  discriminator?: string;
  bot?: boolean;
};

type DiscordMember = {
  user?: DiscordUser;
  nick?: string | null;
};

function isResultsEvent(row: FeedRow): boolean {
  if (row.event_type === "result") return true;
  const channel = String(row.metadata?.channel || "").toLowerCase();
  return channel === "results";
}

function isNatterEvent(row: FeedRow): boolean {
  if (row.event_type === "natter") return true;
  const channel = String(row.metadata?.channel || "").toLowerCase();
  return channel === "natter";
}

function isNotificationsEvent(row: FeedRow): boolean {
  if (row.event_type === "notification") return true;
  const channel = String(row.metadata?.channel || "").toLowerCase();
  return channel === "notifications" || channel === "notification";
}

function wantsOwnerPing(row: FeedRow): boolean {
  if (row.event_type === "owner") return true;
  if (row.metadata?.ping === true || row.metadata?.ping === "true") return true;
  return Boolean(row.metadata?.owner_tag || row.metadata?.mention);
}

function publicNatterImageUrl(
  supabaseUrl: string,
  metadata: Record<string, unknown> | null
): string | null {
  if (!metadata) return null;
  const direct = String(metadata.image_url || "").trim();
  if (/^https?:\/\//i.test(direct)) return direct.slice(0, 2048);

  const path = String(metadata.image_path || "")
    .trim()
    .replace(/^\/+/, "");
  if (!path || path.includes("..")) return null;

  const base = (supabaseUrl || "").replace(/\/+$/, "");
  if (!base) return null;
  return `${base}/storage/v1/object/public/natter-media/${path}`.slice(0, 2048);
}

function embedFor(row: FeedRow, supabaseUrl = "") {
  const colors: Record<string, number> = {
    result: 0xe10600, // Sky-ish red
    transfer: 0x00a651, // green
    listing: 0xffcc00, // amber
    auction: 0x0057b8, // blue
    draft: 0x7b2cbf, // purple
    manager: 0x3498db,
    owner: 0xf1c40f,
    title: 0xffd700,
    cup: 0xffd700,
    relegation: 0x995533,
    playoff: 0x9b59b6,
    release: 0xbcbc80,
    natter: 0x57f287,
    notification: 0x5865f2,
    other: 0x111111,
  };
  const color =
    row.color ??
    colors[row.event_type] ??
    colors.other;

  const results = isResultsEvent(row);
  const natter = isNatterEvent(row);
  const notifications = isNotificationsEvent(row);
  const imageUrl = natter
    ? publicNatterImageUrl(supabaseUrl, row.metadata)
    : null;

  return {
    title: row.headline.slice(0, 256),
    description: (row.body || "").slice(0, 4000) || undefined,
    color,
    ...(imageUrl ? { image: { url: imageUrl } } : {}),
    footer: {
      text: results
        ? "GPSL Results"
        : natter
          ? "GPSL Natter"
          : notifications
            ? "GPSL Notifications"
            : "GPSL News",
    },
    timestamp: new Date().toISOString(),
  };
}

async function fetchGuildMembers(
  botToken: string,
  guildId: string
): Promise<DiscordMember[]> {
  const members: DiscordMember[] = [];
  let after: string | null = null;

  for (let page = 0; page < 50; page++) {
    const url = new URL(`${DISCORD_API}/guilds/${guildId}/members`);
    url.searchParams.set("limit", "1000");
    if (after) url.searchParams.set("after", after);

    const res = await fetch(url, {
      headers: {
        Authorization: `Bot ${botToken}`,
        "Content-Type": "application/json",
      },
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(
        `Discord guild members ${res.status}: ${text.slice(0, 200)}`
      );
    }

    const batch = (await res.json()) as DiscordMember[];
    if (!Array.isArray(batch) || batch.length === 0) break;

    members.push(...batch);
    const last = batch[batch.length - 1]?.user?.id;
    if (!last || batch.length < 1000) break;
    after = last;
  }

  return members;
}

function matchMemberId(
  members: DiscordMember[],
  ownerTag: string
): string | null {
  const needle = ownerTag.replace(/^@+/, "").trim().toLowerCase();
  if (!needle) return null;

  for (const m of members) {
    const u = m.user;
    if (!u || u.bot) continue;
    const candidates = [
      m.nick,
      u.global_name,
      u.username,
      u.discriminator && u.discriminator !== "0"
        ? `${u.username}#${u.discriminator}`
        : null,
    ]
      .filter(Boolean)
      .map((s) => String(s).trim().toLowerCase());

    if (candidates.includes(needle)) return u.id;
  }
  return null;
}

class DiscordRateLimitError extends Error {
  retryAfterMs: number;
  constructor(retryAfterSec: number, detail: string) {
    super(`Discord webhook 429: ${detail}`);
    this.name = "DiscordRateLimitError";
    this.retryAfterMs = Math.max(300, Math.ceil(retryAfterSec * 1000));
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function parseRetryAfterSec(res: Response, bodyText: string): number {
  const header = res.headers.get("retry-after");
  if (header && Number.isFinite(Number(header))) {
    return Math.max(0.3, Number(header));
  }
  try {
    const j = JSON.parse(bodyText) as { retry_after?: number };
    if (typeof j.retry_after === "number" && Number.isFinite(j.retry_after)) {
      return Math.max(0.3, j.retry_after);
    }
  } catch {
    /* ignore */
  }
  return 1;
}

async function postWebhook(
  webhookUrl: string,
  embeds: Record<string, unknown>[],
  opts?: {
    username?: string;
    content?: string;
    allowedMentions?: { users?: string[]; parse?: string[] };
  }
) {
  const payload: Record<string, unknown> = {
    username: opts?.username || "GPSL News",
    embeds,
  };
  if (opts?.content) {
    payload.content = opts.content.slice(0, 2000);
  }
  if (opts?.allowedMentions) {
    payload.allowed_mentions = opts.allowedMentions;
  }

  // Discord webhooks are ~5 req / 2s per webhook. Retry 429s instead of failing the queue.
  for (let attempt = 0; attempt < 6; attempt++) {
    const res = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (res.ok) return;

    const text = await res.text();
    if (res.status === 429) {
      const waitSec = parseRetryAfterSec(res, text);
      if (attempt < 5) {
        await sleep(Math.ceil(waitSec * 1000) + 150);
        continue;
      }
      throw new DiscordRateLimitError(waitSec, text.slice(0, 300));
    }

    throw new Error(`Discord webhook ${res.status}: ${text.slice(0, 300)}`);
  }
}

function webhookForRow(
  row: FeedRow,
  newsUrl: string,
  resultsUrl: string | null,
  natterUrl: string | null,
  notificationsUrl: string | null
): { url: string; username: string } {
  if (isResultsEvent(row)) {
    if (!resultsUrl) {
      throw new Error(
        "DISCORD_RESULTS_WEBHOOK_URL secret missing — result not posted to #gpsl-news. Add the #gpsl-results webhook secret and redeploy discord-sky-feed."
      );
    }
    return { url: resultsUrl, username: "GPSL Results" };
  }
  if (isNatterEvent(row)) {
    if (!natterUrl) {
      throw new Error(
        "DISCORD_NATTER_WEBHOOK_URL secret missing — natter not posted to #gpsl-news. Add the #gpsl-natter webhook secret and redeploy discord-sky-feed."
      );
    }
    return { url: natterUrl, username: "GPSL Natter" };
  }
  if (isNotificationsEvent(row)) {
    if (!notificationsUrl) {
      throw new Error(
        "DISCORD_NOTIFICATIONS_WEBHOOK_URL secret missing — notification not posted to #gpsl-news. Add the #gpsl-notifications webhook secret and redeploy discord-sky-feed."
      );
    }
    return { url: notificationsUrl, username: "GPSL Notifications" };
  }
  return { url: newsUrl, username: "GPSL News" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const webhookUrl = Deno.env.get("DISCORD_WEBHOOK_URL");
    const resultsWebhookUrl =
      Deno.env.get("DISCORD_RESULTS_WEBHOOK_URL") ||
      Deno.env.get("DISCORD_WEBHOOK_RESULTS_URL") ||
      "";
    const natterWebhookUrl =
      Deno.env.get("DISCORD_NATTER_WEBHOOK_URL") ||
      Deno.env.get("DISCORD_WEBHOOK_NATTER_URL") ||
      "";
    const notificationsWebhookUrl =
      Deno.env.get("DISCORD_NOTIFICATIONS_WEBHOOK_URL") ||
      Deno.env.get("DISCORD_WEBHOOK_NOTIFICATIONS_URL") ||
      "";
    const feedKey = Deno.env.get("DISCORD_FEED_INVOKE_KEY") ||
      Deno.env.get("CRON_API_KEY") ||
      "";
    const botToken = Deno.env.get("DISCORD_BOT_TOKEN") || "";
    const guildId = Deno.env.get("DISCORD_GUILD_ID") || "";
    const adminEmail = "rotavator66@outlook.com";

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }
    if (!webhookUrl) {
      return jsonResponse(
        {
          error:
            "DISCORD_WEBHOOK_URL secret missing — add it under Edge Functions → Secrets",
        },
        500
      );
    }

    // Auth: invoke key (cron/webhook/SQL) OR admin JWT
    const invokeHeader = (
      req.headers.get("x-discord-feed-key") ||
      req.headers.get("apikey") ||
      ""
    ).trim();
    const authBearer = (req.headers.get("Authorization") || "")
      .replace(/^Bearer\s+/i, "")
      .trim();

    let authorized = false;
    if (feedKey && (invokeHeader === feedKey || authBearer === feedKey)) {
      authorized = true;
    } else if (authBearer && authBearer === serviceRoleKey) {
      // Database Webhooks / server-side callers
      authorized = true;
    } else if (authBearer.startsWith("eyJ")) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: `Bearer ${authBearer}` } },
      });
      const {
        data: { user },
      } = await userClient.auth.getUser();
      if (user && (user.email || "").toLowerCase() === adminEmail) {
        authorized = true;
      }
    }

    if (!authorized) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch {
      body = {};
    }

    // Optional: routing / secrets check (no Discord post)
    if (body?.diagnose === true) {
      return jsonResponse({
        ok: true,
        diagnose: true,
        news_webhook_configured: Boolean(webhookUrl),
        results_webhook_configured: Boolean(resultsWebhookUrl),
        natter_webhook_configured: Boolean(natterWebhookUrl),
        notifications_webhook_configured: Boolean(notificationsWebhookUrl),
        routing: {
          result_events: resultsWebhookUrl
            ? "DISCORD_RESULTS_WEBHOOK_URL → #gpsl-results"
            : "BLOCKED until DISCORD_RESULTS_WEBHOOK_URL is set",
          natter_events: natterWebhookUrl
            ? "DISCORD_NATTER_WEBHOOK_URL → #gpsl-natter"
            : "BLOCKED until DISCORD_NATTER_WEBHOOK_URL is set",
          notification_events: notificationsWebhookUrl
            ? "DISCORD_NOTIFICATIONS_WEBHOOK_URL → #gpsl-notifications"
            : "BLOCKED until DISCORD_NOTIFICATIONS_WEBHOOK_URL is set",
          other_events: "DISCORD_WEBHOOK_URL → #gpsl-news",
        },
        note:
          "Create each webhook inside its Discord channel. Secrets live under Edge Functions → Secrets (project-wide), then redeploy discord-sky-feed.",
      });
    }

    // Optional: post a one-off test embed
    if (body?.test === true) {
      const channel = String(body?.channel || "news").toLowerCase();
      const toResults = channel === "results";
      const toNatter = channel === "natter";
      const toNotifications =
        channel === "notifications" || channel === "notification";
      if (toResults && !resultsWebhookUrl) {
        return jsonResponse(
          {
            ok: false,
            error:
              "DISCORD_RESULTS_WEBHOOK_URL secret missing — cannot test #gpsl-results. Add it under Edge Functions → Secrets and redeploy.",
            channel: "results",
            used_results_webhook: false,
            results_webhook_configured: false,
          },
          400
        );
      }
      if (toNatter && !natterWebhookUrl) {
        return jsonResponse(
          {
            ok: false,
            error:
              "DISCORD_NATTER_WEBHOOK_URL secret missing — cannot test #gpsl-natter. Add it under Edge Functions → Secrets and redeploy.",
            channel: "natter",
            used_natter_webhook: false,
            natter_webhook_configured: false,
          },
          400
        );
      }
      if (toNotifications && !notificationsWebhookUrl) {
        return jsonResponse(
          {
            ok: false,
            error:
              "DISCORD_NOTIFICATIONS_WEBHOOK_URL secret missing — cannot test #gpsl-notifications. Add it under Edge Functions → Secrets and redeploy.",
            channel: "notifications",
            used_notifications_webhook: false,
            notifications_webhook_configured: false,
          },
          400
        );
      }
      const target = toResults
        ? resultsWebhookUrl
        : toNatter
          ? natterWebhookUrl
          : toNotifications
            ? notificationsWebhookUrl
            : webhookUrl;
      const label = toResults
        ? "RESULTS"
        : toNatter
          ? "NATTER"
          : toNotifications
            ? "NOTIFICATIONS"
            : "NEWS";
      const channelName = toResults
        ? "#gpsl-results"
        : toNatter
          ? "#gpsl-natter"
          : toNotifications
            ? "#gpsl-notifications"
            : "#gpsl-news";
      await postWebhook(
        target,
        [
          {
            title: `🚨 GPSL ${label} — TEST`,
            description: `${channelName} webhook is connected. This message must appear in ${channelName} only.`,
            color: toNatter
              ? 0x57f287
              : toNotifications
                ? 0x5865f2
                : 0xe10600,
            footer: {
              text: toResults
                ? "GPSL Results"
                : toNatter
                  ? "GPSL Natter"
                  : toNotifications
                    ? "GPSL Notifications"
                    : "GPSL News",
            },
            timestamp: new Date().toISOString(),
          },
        ],
        {
          username: toResults
            ? "GPSL Results"
            : toNatter
              ? "GPSL Natter"
              : toNotifications
                ? "GPSL Notifications"
                : "GPSL News",
        }
      );
      return jsonResponse({
        ok: true,
        test: true,
        channel: toResults
          ? "results"
          : toNatter
            ? "natter"
            : toNotifications
              ? "notifications"
              : "news",
        used_results_webhook: Boolean(toResults && resultsWebhookUrl),
        used_natter_webhook: Boolean(toNatter && natterWebhookUrl),
        used_notifications_webhook: Boolean(
          toNotifications && notificationsWebhookUrl
        ),
        results_webhook_configured: Boolean(resultsWebhookUrl),
        natter_webhook_configured: Boolean(natterWebhookUrl),
        notifications_webhook_configured: Boolean(notificationsWebhookUrl),
      });
    }

    // Optional: direct event (from SQL/webhook payload)
    if (body?.headline && body?.event_type) {
      const directRow: FeedRow = {
        id: 0,
        event_type: String(body.event_type),
        headline: String(body.headline),
        body: body.body != null ? String(body.body) : null,
        color: typeof body.color === "number" ? body.color : null,
        metadata:
          body.metadata && typeof body.metadata === "object"
            ? (body.metadata as Record<string, unknown>)
            : body.channel
              ? { channel: body.channel }
              : null,
      };
      const target = webhookForRow(
        directRow,
        webhookUrl,
        resultsWebhookUrl || null,
        natterWebhookUrl || null,
        notificationsWebhookUrl || null
      );
      await postWebhook(target.url, [embedFor(directRow, supabaseUrl)], {
        username: target.username,
      });
    }

    let posted = 0;
    let postedResults = 0;
    let postedNatter = 0;
    let postedNotifications = 0;
    let postedNews = 0;
    const errors: string[] = [];
    const warnings: string[] = [];

    // Claim rows atomically so concurrent flushes cannot double-post the same item
    let pending: FeedRow[] = [];
    const { data: claimed, error: claimError } = await adminClient.rpc(
      "gpsl_discord_feed_claim_pending",
      { p_limit: 10 }
    );
    if (claimError) {
      // Fallback for DBs that have not run the claim patch yet
      const { data: rows, error } = await adminClient
        .from("gpsl_discord_feed_queue")
        .select("id, event_type, headline, body, color, metadata, attempts")
        .eq("status", "pending")
        .order("id", { ascending: true })
        .limit(10);
      if (error) {
        return jsonResponse({ error: error.message }, 500);
      }
      pending = (rows || []) as FeedRow[];
      if (pending.length) {
        warnings.push(
          "gpsl_discord_feed_claim_pending missing — run gpsl_discord_feed_claim_pending.sql to stop double Discord posts"
        );
      }
    } else {
      pending = (claimed || []) as FeedRow[];
    }

    if (
      pending.some((r) => isResultsEvent(r)) &&
      !resultsWebhookUrl
    ) {
      warnings.push(
        "DISCORD_RESULTS_WEBHOOK_URL not set — result items will stay in error until the #gpsl-results webhook secret is added"
      );
    }
    if (pending.some((r) => isNatterEvent(r)) && !natterWebhookUrl) {
      warnings.push(
        "DISCORD_NATTER_WEBHOOK_URL not set — natter items will stay in error until the #gpsl-natter webhook secret is added"
      );
    }
    if (
      pending.some((r) => isNotificationsEvent(r)) &&
      !notificationsWebhookUrl
    ) {
      warnings.push(
        "DISCORD_NOTIFICATIONS_WEBHOOK_URL not set — notification items will stay in error until the #gpsl-notifications webhook secret is added"
      );
    }

    // Lazy-load guild members once if any posts need a real ping
    let guildMembers: DiscordMember[] | null = null;
    const needsOwnerResolve = pending.some((r) => wantsOwnerPing(r));

    if (needsOwnerResolve && botToken && guildId) {
      try {
        guildMembers = await fetchGuildMembers(botToken, guildId);
      } catch {
        guildMembers = null;
      }
    }

    for (const row of pending) {
      try {
        let content: string | undefined;
        let allowedMentions: { users?: string[]; parse?: string[] } |
          undefined;

        if (wantsOwnerPing(row)) {
          const rawTag = String(
            row.metadata?.owner_tag ||
              row.metadata?.mention ||
              ""
          ).replace(/^@+/, "").trim();
          const displayMention = rawTag ? `@${rawTag}` : "";
          let ping: string | null = null;
          let userId: string | null = null;

          if (rawTag && guildMembers) {
            userId = matchMemberId(guildMembers, rawTag);
            if (userId) ping = `<@${userId}>`;
          }

          // Discord only notifies from message content (not embed text)
          content = ping || displayMention || undefined;
          if (userId) {
            allowedMentions = { users: [userId] };
          } else if (displayMention) {
            // Soft mention text — may not notify without snowflake id
            allowedMentions = { parse: [] };
          }

          // Ensure embed body shows @tag even if older queued rows lack it
          if (displayMention && row.body && !row.body.includes(displayMention)) {
            row.body = row.body.replace(
              /(have appointed )([^.]+)\./i,
              `$1${displayMention}.`
            );
          } else if (displayMention && row.body && !/@\S/.test(row.body)) {
            row.body = row.body.replace(
              /(have appointed )([^.]+)\./i,
              `$1${displayMention}.`
            );
          }
        }

        const target = webhookForRow(
          row,
          webhookUrl,
          resultsWebhookUrl || null,
          natterWebhookUrl || null,
          notificationsWebhookUrl || null
        );
        const embed = embedFor(row, supabaseUrl);
        try {
          await postWebhook(target.url, [embed], {
            username: target.username,
            content,
            allowedMentions,
          });
        } catch (postErr) {
          const postMsg =
            postErr instanceof Error ? postErr.message : String(postErr);
          const rateLimited =
            postErr instanceof DiscordRateLimitError ||
            /\b429\b/.test(postMsg) ||
            /rate limited/i.test(postMsg);
          // Discord sometimes rejects embed images (size/URL). Still post text.
          // Do not retry text-only on 429 — that burns the rate limit further.
          if (!rateLimited && isNatterEvent(row) && embed.image) {
            const { image: _drop, ...textOnly } = embed;
            await postWebhook(target.url, [textOnly], {
              username: target.username,
              content,
              allowedMentions,
            });
            warnings.push(
              `#${row.id}: natter image failed (${postMsg}) — posted text only`
            );
          } else {
            throw postErr;
          }
        }
        const { error: updErr } = await adminClient
          .from("gpsl_discord_feed_queue")
          .update({
            status: "posted",
            posted_at: new Date().toISOString(),
            last_error: null,
          })
          .eq("id", row.id);
        if (updErr) throw new Error(updErr.message);
        posted += 1;
        if (isResultsEvent(row)) postedResults += 1;
        else if (isNatterEvent(row)) postedNatter += 1;
        else if (isNotificationsEvent(row)) postedNotifications += 1;
        else postedNews += 1;
        // Discord webhooks: stay under ~5/2s — pause between successful posts
        await sleep(700);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        const rateLimited =
          err instanceof DiscordRateLimitError ||
          /\b429\b/.test(message) ||
          /rate limited/i.test(message);

        if (rateLimited) {
          // Keep pending so the next flush/cron can retry — do not mark as error
          warnings.push(`#${row.id}: rate limited — left pending for retry`);
          await adminClient
            .from("gpsl_discord_feed_queue")
            .update({
              status: "pending",
              last_error: message.slice(0, 500),
              attempts: Number((row as { attempts?: number }).attempts || 0) + 1,
            })
            .eq("id", row.id);
          const waitMs =
            err instanceof DiscordRateLimitError ? err.retryAfterMs : 1000;
          await sleep(waitMs);
          // Stop this batch; remaining pending rows stay for the next run
          break;
        }

        errors.push(`#${row.id}: ${message}`);
        await adminClient
          .from("gpsl_discord_feed_queue")
          .update({
            status: "error",
            last_error: message.slice(0, 500),
            attempts: Number((row as { attempts?: number }).attempts || 0) + 1,
          })
          .eq("id", row.id);
      }
    }

    return jsonResponse({
      ok: true,
      pending: pending.length,
      posted,
      posted_news: postedNews,
      posted_results: postedResults,
      posted_natter: postedNatter,
      posted_notifications: postedNotifications,
      results_webhook_configured: Boolean(resultsWebhookUrl),
      natter_webhook_configured: Boolean(natterWebhookUrl),
      notifications_webhook_configured: Boolean(notificationsWebhookUrl),
      warnings,
      errors,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
