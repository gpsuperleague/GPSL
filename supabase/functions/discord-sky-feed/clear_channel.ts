/** Clear Discord channel messages via bot (Manage Messages).
 *
 * Edge Functions time out (~60s gateway). Prefer short batches and let the
 * admin UI re-invoke until the channel is empty.
 */

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
  if (res.status === 429) {
    const text = await res.text();
    let wait = 1;
    try {
      const j = JSON.parse(text) as { retry_after?: number };
      if (typeof j.retry_after === "number") wait = j.retry_after;
    } catch {
      /* ignore */
    }
    await sleep(Math.ceil(wait * 1000) + 150);
    return fetchMessages(botToken, channelId, before);
  }
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Fetch messages ${res.status}: ${text.slice(0, 250)}`);
  }
  const rows = (await res.json()) as DiscordMessage[];
  return Array.isArray(rows) ? rows : [];
}

async function bulkDelete(
  botToken: string,
  channelId: string,
  ids: string[]
): Promise<number> {
  if (ids.length === 0) return 0;
  if (ids.length === 1) {
    await deleteOne(botToken, channelId, ids[0]);
    return 1;
  }
  const res = await discordFetch(
    botToken,
    `/channels/${channelId}/messages/bulk-delete`,
    {
      method: "POST",
      body: JSON.stringify({ messages: ids.slice(0, 100) }),
    }
  );
  if (res.status === 204 || res.ok) return ids.length;
  if (res.status === 429) {
    const text = await res.text();
    let wait = 1;
    try {
      const j = JSON.parse(text) as { retry_after?: number };
      if (typeof j.retry_after === "number") wait = j.retry_after;
    } catch {
      /* ignore */
    }
    await sleep(Math.ceil(wait * 1000) + 150);
    return bulkDelete(botToken, channelId, ids);
  }
  const text = await res.text();
  // Mixed ages / invalid → fall back to a few singles (caller time-budgets)
  if (res.status === 400) {
    let n = 0;
    for (const id of ids.slice(0, 20)) {
      await deleteOne(botToken, channelId, id);
      n += 1;
      await sleep(280);
    }
    return n;
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
    await sleep(Math.ceil(wait * 1000) + 150);
    return deleteOne(botToken, channelId, messageId);
  }
  const text = await res.text();
  throw new Error(`Delete ${messageId} ${res.status}: ${text.slice(0, 200)}`);
}

export async function clearDiscordChannel(opts: {
  botToken: string;
  channelId: string;
  /** Soft cap per request. Default 100. */
  maxDelete?: number;
  /** Wall-clock budget ms (stay under edge gateway). Default 22000. */
  timeBudgetMs?: number;
  keepPinned?: boolean;
}): Promise<{
  ok: boolean;
  deleted: number;
  scanned: number;
  skipped_pinned: number;
  more_remain: boolean;
  timed_out_budget: boolean;
  error?: string;
}> {
  const maxDelete = Math.max(1, Math.min(opts.maxDelete ?? 100, 200));
  const timeBudgetMs = Math.max(5000, Math.min(opts.timeBudgetMs ?? 22000, 45000));
  const keepPinned = opts.keepPinned !== false;
  const started = Date.now();
  const deadline = started + timeBudgetMs;

  let deleted = 0;
  let scanned = 0;
  let skippedPinned = 0;
  const cutoff = Date.now() - TWO_WEEKS_MS;

  const timeLeft = () => deadline - Date.now();

  try {
    while (deleted < maxDelete && timeLeft() > 2500) {
      // Always fetch from the head — deletes shift the window
      const batch = await fetchMessages(opts.botToken, opts.channelId);
      if (!batch.length) {
        return {
          ok: true,
          deleted,
          scanned,
          skipped_pinned: skippedPinned,
          more_remain: false,
          timed_out_budget: false,
        };
      }
      scanned += batch.length;

      const candidates = batch.filter((m) => {
        if (keepPinned && m.pinned) {
          skippedPinned += 1;
          return false;
        }
        return true;
      });

      if (!candidates.length) {
        // Only pinned left in the latest page
        return {
          ok: true,
          deleted,
          scanned,
          skipped_pinned: skippedPinned,
          more_remain: false,
          timed_out_budget: false,
        };
      }

      const recent = candidates
        .filter((m) => snowflakeCreatedAtMs(m.id) >= cutoff)
        .map((m) => m.id);
      const older = candidates
        .filter((m) => snowflakeCreatedAtMs(m.id) < cutoff)
        .map((m) => m.id);

      // Prefer bulk (fast) for <14d messages
      if (recent.length >= 2 && timeLeft() > 3000 && deleted < maxDelete) {
        const take = Math.min(100, recent.length, maxDelete - deleted);
        const n = await bulkDelete(
          opts.botToken,
          opts.channelId,
          recent.slice(0, take)
        );
        deleted += n;
        await sleep(500);
        continue;
      }

      if (recent.length === 1 && timeLeft() > 2000 && deleted < maxDelete) {
        await deleteOne(opts.botToken, opts.channelId, recent[0]);
        deleted += 1;
        await sleep(280);
        continue;
      }

      // Older than 14 days: Discord requires single deletes — do a few only
      for (const id of older) {
        if (deleted >= maxDelete || timeLeft() < 2000) break;
        await deleteOne(opts.botToken, opts.channelId, id);
        deleted += 1;
        await sleep(280);
      }

      // If we made no progress this pass, stop to avoid spinning
      if (recent.length === 0 && older.length === 0) break;
      if (timeLeft() < 2000) break;
    }

    const peek = await fetchMessages(opts.botToken, opts.channelId);
    const remaining = peek.filter((m) => !(keepPinned && m.pinned));
    const hitBudget = timeLeft() < 2000 || deleted >= maxDelete;

    return {
      ok: true,
      deleted,
      scanned,
      skipped_pinned: skippedPinned,
      more_remain: remaining.length > 0,
      timed_out_budget: hitBudget && remaining.length > 0,
    };
  } catch (err) {
    return {
      ok: deleted > 0, // partial progress still useful
      deleted,
      scanned,
      skipped_pinned: skippedPinned,
      more_remain: true,
      timed_out_budget: timeLeft() < 2000,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
