/** Clear Discord channel messages via bot (Manage Messages). */

const DISCORD_API = "https://discord.com/api/v10";
const TWO_WEEKS_MS = 14 * 24 * 60 * 60 * 1000;
const DISCORD_EPOCH = 1420070400000n;

export type ClearChannelKey =
  | "news"
  | "results"
  | "intl_results"
  | "natter"
  | "notifications"
  | "tables"
  | "intl_tables"
  | "scheduled"
  | "intl_scheduled"
  | "whos_who";

export const CLEAR_CHANNEL_LABELS: Record<ClearChannelKey, string> = {
  news: "#gpsl-news",
  results: "#gpsl-results",
  intl_results: "#gpsl-intl-results",
  natter: "#gpsl-natter",
  notifications: "#gpsl-notifications",
  tables: "#gpsl-tables",
  intl_tables: "#gpsl-intl-tables",
  scheduled: "#gpsl-scheduled",
  intl_scheduled: "#gpsl-intl-scheduled",
  whos_who: "#whos-who",
};

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function parseWebhookParts(
  webhookUrl: string
): { id: string; token: string } | null {
  const m = String(webhookUrl || "").match(
    /discord(?:app)?\.com\/api\/webhooks\/(\d+)\/([^/?#]+)/i
  );
  if (!m) return null;
  return { id: m[1], token: m[2] };
}

function snowflakeCreatedAtMs(id: string): number {
  try {
    return Number((BigInt(id) >> 22n) + DISCORD_EPOCH);
  } catch {
    return 0;
  }
}

type DiscordMessage = { id: string; pinned?: boolean };

async function discordFetch(
  botToken: string,
  path: string,
  init?: RequestInit
): Promise<Response> {
  return fetch(`${DISCORD_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
      ...(init?.headers || {}),
    },
  });
}

export async function resolveChannelIdFromWebhook(
  webhookUrl: string
): Promise<{ channelId: string; guildId?: string } | { error: string }> {
  const parts = parseWebhookParts(webhookUrl);
  if (!parts) {
    return { error: "Webhook URL is missing or invalid" };
  }
  const res = await fetch(
    `${DISCORD_API}/webhooks/${parts.id}/${parts.token}`
  );
  if (!res.ok) {
    const text = await res.text();
    return {
      error: `Webhook lookup failed (${res.status}): ${text.slice(0, 200)}`,
    };
  }
  const data = (await res.json()) as {
    channel_id?: string;
    guild_id?: string;
  };
  if (!data.channel_id) {
    return { error: "Webhook has no channel_id" };
  }
  return { channelId: data.channel_id, guildId: data.guild_id };
}

async function fetchMessages(
  botToken: string,
  channelId: string,
  before?: string
): Promise<DiscordMessage[]> {
  const qs = new URLSearchParams({ limit: "100" });
  if (before) qs.set("before", before);
  const res = await discordFetch(
    botToken,
    `/channels/${channelId}/messages?${qs.toString()}`
  );
  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `Fetch messages ${res.status}: ${text.slice(0, 250)}`
    );
  }
  const rows = (await res.json()) as DiscordMessage[];
  return Array.isArray(rows) ? rows : [];
}

async function bulkDelete(
  botToken: string,
  channelId: string,
  ids: string[]
): Promise<void> {
  if (ids.length < 2) {
    if (ids.length === 1) {
      await deleteOne(botToken, channelId, ids[0]);
    }
    return;
  }
  const res = await discordFetch(
    botToken,
    `/channels/${channelId}/messages/bulk-delete`,
    {
      method: "POST",
      body: JSON.stringify({ messages: ids.slice(0, 100) }),
    }
  );
  if (res.status === 204 || res.ok) return;
  const text = await res.text();
  // Fallback: delete one-by-one if bulk fails (e.g. mixed ages)
  if (res.status === 400) {
    for (const id of ids) {
      await deleteOne(botToken, channelId, id);
      await sleep(350);
    }
    return;
  }
  throw new Error(`Bulk delete ${res.status}: ${text.slice(0, 250)}`);
}

async function deleteOne(
  botToken: string,
  channelId: string,
  messageId: string
): Promise<void> {
  const res = await discordFetch(
    botToken,
    `/channels/${channelId}/messages/${messageId}`,
    { method: "DELETE" }
  );
  if (res.status === 204 || res.ok || res.status === 404) return;
  if (res.status === 429) {
    const text = await res.text();
    let wait = 1;
    try {
      const j = JSON.parse(text) as { retry_after?: number };
      if (typeof j.retry_after === "number") wait = j.retry_after;
    } catch {
      /* ignore */
    }
    await sleep(Math.ceil(wait * 1000) + 100);
    return deleteOne(botToken, channelId, messageId);
  }
  const text = await res.text();
  throw new Error(`Delete ${messageId} ${res.status}: ${text.slice(0, 200)}`);
}

export async function clearDiscordChannel(opts: {
  botToken: string;
  channelId: string;
  /** Soft cap per request (edge timeout). Default 500. */
  maxDelete?: number;
  keepPinned?: boolean;
}): Promise<{
  ok: boolean;
  deleted: number;
  scanned: number;
  skipped_pinned: number;
  more_remain: boolean;
  error?: string;
}> {
  const maxDelete = Math.max(1, Math.min(opts.maxDelete ?? 500, 1500));
  const keepPinned = opts.keepPinned !== false;
  let deleted = 0;
  let scanned = 0;
  let skippedPinned = 0;
  let cursor: string | undefined;
  const cutoff = Date.now() - TWO_WEEKS_MS;
  let pages = 0;

  try {
    while (deleted < maxDelete && pages < 40) {
      pages += 1;
      const batch = await fetchMessages(opts.botToken, opts.channelId, cursor);
      if (!batch.length) {
        return {
          ok: true,
          deleted,
          scanned,
          skipped_pinned: skippedPinned,
          more_remain: false,
        };
      }
      scanned += batch.length;
      cursor = batch[batch.length - 1]?.id;

      const candidates = batch.filter((m) => {
        if (keepPinned && m.pinned) {
          skippedPinned += 1;
          return false;
        }
        return true;
      });

      if (!candidates.length) {
        if (batch.length < 100) {
          return {
            ok: true,
            deleted,
            scanned,
            skipped_pinned: skippedPinned,
            more_remain: false,
          };
        }
        await sleep(300);
        continue;
      }

      const recent: string[] = [];
      const older: string[] = [];
      for (const m of candidates) {
        if (snowflakeCreatedAtMs(m.id) >= cutoff) recent.push(m.id);
        else older.push(m.id);
      }

      // Bulk recent in chunks of 100
      while (recent.length && deleted < maxDelete) {
        const take = Math.min(100, recent.length, maxDelete - deleted);
        const chunk = recent.splice(0, take);
        if (chunk.length >= 2) {
          await bulkDelete(opts.botToken, opts.channelId, chunk);
          deleted += chunk.length;
          await sleep(600);
        } else if (chunk.length === 1) {
          await deleteOne(opts.botToken, opts.channelId, chunk[0]);
          deleted += 1;
          await sleep(350);
        }
      }

      for (const id of older) {
        if (deleted >= maxDelete) break;
        await deleteOne(opts.botToken, opts.channelId, id);
        deleted += 1;
        await sleep(350);
      }

      if (batch.length < 100) {
        const more = await fetchMessages(opts.botToken, opts.channelId);
        const remaining = more.filter((m) => !(keepPinned && m.pinned));
        return {
          ok: true,
          deleted,
          scanned,
          skipped_pinned: skippedPinned,
          more_remain: remaining.length > 0,
        };
      }
    }

    // Hit maxDelete or page cap — check if more remain
    const peek = await fetchMessages(opts.botToken, opts.channelId);
    const remaining = peek.filter((m) => !(keepPinned && m.pinned));
    return {
      ok: true,
      deleted,
      scanned,
      skipped_pinned: skippedPinned,
      more_remain: remaining.length > 0,
    };
  } catch (err) {
    return {
      ok: false,
      deleted,
      scanned,
      skipped_pinned: skippedPinned,
      more_remain: true,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
