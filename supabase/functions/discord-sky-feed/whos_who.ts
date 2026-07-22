/** Discord #whos-who roster: post once, then silent daily edits. */

export type WhosWhoClub = {
  owner_tag: string;
  club_name: string;
  short_name?: string;
};

export type WhosWhoDivision = {
  slug: string;
  label: string;
  clubs: WhosWhoClub[];
};

export type WhosWhoRoster = {
  ok: boolean;
  reason?: string;
  season_id?: number;
  season_label?: string;
  divisions?: WhosWhoDivision[];
};

const DIVISION_COLORS: Record<string, number> = {
  superleague: 0xff9900,
  championship_a: 0x5865f2,
  championship_b: 0x57f287,
};

function padTag(tag: string, width: number): string {
  const t = tag.slice(0, width);
  return t + " ".repeat(Math.max(0, width - t.length));
}

export function buildWhosWhoEmbeds(roster: WhosWhoRoster): Record<string, unknown>[] {
  const embeds: Record<string, unknown>[] = [];
  const divisions = roster.divisions || [];
  const updated = new Date().toISOString().slice(0, 16).replace("T", " ") + " UTC";

  for (const div of divisions) {
    const clubs = div.clubs || [];
    const maxTag = Math.min(
      24,
      Math.max(8, ...clubs.map((c) => (c.owner_tag || "—").length), 8)
    );
    const lines =
      clubs.length === 0
        ? ["(no clubs registered)"]
        : clubs.map((c) => {
            const rawTag = (c.owner_tag || "").trim();
            const short = String(c.short_name || "").trim();
            const vacant =
              c.vacant === true ||
              !rawTag ||
              rawTag === "—" ||
              (short && rawTag.toUpperCase() === short.toUpperCase());
            const tag = vacant ? "—" : padTag(rawTag, maxTag);
            const club = (c.club_name || c.short_name || "—").trim();
            return vacant ? `${padTag("—", maxTag)}  ${club}` : `${tag}  ${club}`;
          });

    // Discord embed description limit 4096; keep a safety margin
    let description = "```\n" + lines.join("\n") + "\n```";
    if (description.length > 3900) {
      description = "```\n" + lines.join("\n").slice(0, 3800) + "\n…\n```";
    }

    embeds.push({
      title: div.label || div.slug,
      description,
      color: DIVISION_COLORS[div.slug] ?? 0x99aab5,
      footer: {
        text: `${clubs.length} clubs · ${roster.season_label || "season"} · ${updated}`,
      },
    });
  }

  if (!embeds.length) {
    embeds.push({
      title: "Who's Who",
      description: "No active division registrations found.",
      color: 0x99aab5,
    });
  }

  return embeds.slice(0, 10);
}

export function rosterContentHash(roster: WhosWhoRoster): string {
  const parts: string[] = [];
  for (const d of roster.divisions || []) {
    parts.push(d.slug);
    for (const c of d.clubs || []) {
      parts.push(`${c.owner_tag}|${c.club_name}|${c.short_name || ""}`);
    }
  }
  return parts.join("\n");
}

export function parseWebhookUrl(
  url: string
): { id: string; token: string; base: string } | null {
  const m = String(url || "").match(
    /discord(?:app)?\.com\/api\/(?:v\d+\/)?webhooks\/(\d+)\/([^/?#]+)/i
  );
  if (!m) return null;
  return {
    id: m[1],
    token: m[2],
    base: `https://discord.com/api/v10/webhooks/${m[1]}/${m[2]}`,
  };
}

async function sleep(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

function parseRetryAfterSec(res: Response, text: string): number {
  const h = res.headers.get("retry-after");
  if (h && Number.isFinite(Number(h))) return Math.max(1, Number(h));
  try {
    const j = JSON.parse(text);
    if (j?.retry_after != null) return Math.max(1, Number(j.retry_after));
  } catch {
    /* ignore */
  }
  return 2;
}

async function discordFetch(
  url: string,
  init: RequestInit
): Promise<{ ok: boolean; status: number; json: Record<string, unknown>; text: string }> {
  for (let attempt = 0; attempt < 6; attempt++) {
    const res = await fetch(url, init);
    const text = await res.text();
    if (res.status === 429) {
      const waitSec = parseRetryAfterSec(res, text);
      if (attempt < 5) {
        await sleep(Math.ceil(waitSec * 1000) + 150);
        continue;
      }
    }
    let json: Record<string, unknown> = {};
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = {};
    }
    return { ok: res.ok, status: res.status, json, text };
  }
  return { ok: false, status: 429, json: {}, text: "rate limited" };
}

export type PublishWhosWhoResult = {
  ok: boolean;
  action: "created" | "edited" | "unchanged" | "error";
  message_id?: string;
  error?: string;
  club_count?: number;
};

export async function publishWhosWho(opts: {
  webhookUrl: string;
  roster: WhosWhoRoster;
  existingMessageId: string | null;
  force?: boolean;
  contentHash: string;
  previousHash: string | null;
}): Promise<PublishWhosWhoResult> {
  const parsed = parseWebhookUrl(opts.webhookUrl);
  if (!parsed) {
    return { ok: false, action: "error", error: "Invalid DISCORD_WHOS_WHO_WEBHOOK_URL" };
  }

  if (
    !opts.force &&
    opts.existingMessageId &&
    opts.previousHash &&
    opts.previousHash === opts.contentHash
  ) {
    return {
      ok: true,
      action: "unchanged",
      message_id: opts.existingMessageId,
    };
  }

  const embeds = buildWhosWhoEmbeds(opts.roster);
  const clubCount = (opts.roster.divisions || []).reduce(
    (n, d) => n + (d.clubs?.length || 0),
    0
  );

  const payload = {
    username: "GPSL Who's Who",
    // No content pings — embeds only; never @everyone / user mentions
    allowed_mentions: { parse: [] as string[] },
    embeds,
  };

  if (opts.existingMessageId) {
    const editUrl = `${parsed.base}/messages/${opts.existingMessageId}`;
    const edited = await discordFetch(editUrl, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (edited.ok) {
      return {
        ok: true,
        action: "edited",
        message_id: opts.existingMessageId,
        club_count: clubCount,
      };
    }
    // Missing message → fall through to create
    if (edited.status !== 404) {
      return {
        ok: false,
        action: "error",
        error: `Discord edit ${edited.status}: ${edited.text.slice(0, 300)}`,
      };
    }
  }

  const created = await discordFetch(`${parsed.base}?wait=true`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!created.ok) {
    return {
      ok: false,
      action: "error",
      error: `Discord create ${created.status}: ${created.text.slice(0, 300)}`,
    };
  }
  const messageId = String(created.json.id || "");
  if (!messageId) {
    return {
      ok: false,
      action: "error",
      error: "Discord create succeeded but returned no message id",
    };
  }
  return {
    ok: true,
    action: "created",
    message_id: messageId,
    club_count: clubCount,
  };
}
