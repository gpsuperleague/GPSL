/** Discord club directory: short code · club · owner tag · league (SL/CA/CB). Post once, then silent edits. */

import { discordFetch, parseWebhookUrl } from "./whos_who.ts";

const LEAGUE_CODES: Record<string, string> = {
  superleague: "SL",
  championship_a: "CA",
  championship_b: "CB",
};

export type ClubDirectory = {
  ok: boolean;
  reason?: string;
  season_label?: string;
  clubs?: {
    short_name: string;
    club_name?: string | null;
    owner_tag?: string | null;
    division?: string | null;
  }[];
};

type DirectoryRow = { code: string; club: string; owner: string; league: string };

const ROWS_PER_EMBED = 35;
const MAX_EMBEDS_PER_MESSAGE = 10;
const MAX_CHARS_PER_MESSAGE = 5500;

function pad(s: string, width: number): string {
  const t = s.length > width ? s.slice(0, width - 1) + "…" : s;
  return t + " ".repeat(Math.max(0, width - t.length));
}

export function directoryRows(dir: ClubDirectory): DirectoryRow[] {
  const rows: DirectoryRow[] = [];
  for (const c of dir.clubs || []) {
    const code = String(c.short_name || "").trim().toUpperCase();
    if (!code) continue;
    const rawTag = String(c.owner_tag || "").trim();
    rows.push({
      code,
      club: String(c.club_name || code).trim(),
      owner: !rawTag || rawTag.toUpperCase() === code ? "—" : rawTag,
      league: LEAGUE_CODES[String(c.division || "")] || "—",
    });
  }
  rows.sort((a, b) => a.code.localeCompare(b.code));
  return rows;
}

export function directoryContentHash(roster: ClubDirectory): string {
  return directoryRows(roster)
    .map((r) => `${r.code}|${r.club}|${r.owner}|${r.league}`)
    .join("\n");
}

function buildEmbeds(roster: ClubDirectory): Record<string, unknown>[] {
  const rows = directoryRows(roster);
  const updated = new Date().toISOString().slice(0, 16).replace("T", " ") + " UTC";
  if (!rows.length) {
    return [
      {
        title: "GPSL Club Directory",
        description: "No clubs found.",
        color: 0x99aab5,
      },
    ];
  }

  const codeW = Math.max(4, ...rows.map((r) => r.code.length));
  const clubW = Math.min(26, Math.max(4, ...rows.map((r) => r.club.length)));
  const ownerW = Math.min(18, Math.max(5, ...rows.map((r) => r.owner.length)));
  const header = `${pad("CODE", codeW)}  ${pad("CLUB", clubW)}  ${pad("OWNER", ownerW)}  LG`;
  const rule = "-".repeat(header.length);

  const counts = { SL: 0, CA: 0, CB: 0 } as Record<string, number>;
  for (const r of rows) counts[r.league] = (counts[r.league] || 0) + 1;

  const chunks: DirectoryRow[][] = [];
  for (let i = 0; i < rows.length; i += ROWS_PER_EMBED) {
    chunks.push(rows.slice(i, i + ROWS_PER_EMBED));
  }

  return chunks.map((chunk, idx) => {
    const lines = chunk.map(
      (r) => `${pad(r.code, codeW)}  ${pad(r.club, clubW)}  ${pad(r.owner, ownerW)}  ${r.league}`
    );
    const embed: Record<string, unknown> = {
      description: "```\n" + [header, rule, ...lines].join("\n") + "\n```",
      color: 0xff9900,
    };
    if (idx === 0) {
      embed.title = "GPSL Club Directory";
    }
    if (idx === chunks.length - 1) {
      embed.footer = {
        text: `${rows.length} clubs · SL ${counts.SL || 0} · CA ${counts.CA || 0} · CB ${
          counts.CB || 0
        } · ${roster.season_label || "season"} · ${updated}`,
      };
    }
    return embed;
  });
}

function embedLength(e: Record<string, unknown>): number {
  const footer = (e.footer as { text?: string } | undefined)?.text || "";
  return String(e.title || "").length + String(e.description || "").length + footer.length;
}

function groupIntoMessages(embeds: Record<string, unknown>[]): Record<string, unknown>[][] {
  const messages: Record<string, unknown>[][] = [];
  let current: Record<string, unknown>[] = [];
  let chars = 0;
  for (const e of embeds) {
    const len = embedLength(e);
    if (
      current.length &&
      (current.length >= MAX_EMBEDS_PER_MESSAGE || chars + len > MAX_CHARS_PER_MESSAGE)
    ) {
      messages.push(current);
      current = [];
      chars = 0;
    }
    current.push(e);
    chars += len;
  }
  if (current.length) messages.push(current);
  return messages;
}

export type PublishClubDirectoryResult = {
  ok: boolean;
  action: "created" | "edited" | "unchanged" | "error";
  message_ids: string[];
  error?: string;
  club_count?: number;
};

export async function publishClubDirectory(opts: {
  webhookUrl: string;
  roster: ClubDirectory;
  existingMessageIds: string[];
  force?: boolean;
  contentHash: string;
  previousHash: string | null;
}): Promise<PublishClubDirectoryResult> {
  const parsed = parseWebhookUrl(opts.webhookUrl);
  if (!parsed) {
    return {
      ok: false,
      action: "error",
      message_ids: opts.existingMessageIds,
      error: "Invalid DISCORD_CLUB_DIRECTORY_WEBHOOK_URL",
    };
  }

  if (
    !opts.force &&
    opts.existingMessageIds.length &&
    opts.previousHash &&
    opts.previousHash === opts.contentHash
  ) {
    return { ok: true, action: "unchanged", message_ids: opts.existingMessageIds };
  }

  const messages = groupIntoMessages(buildEmbeds(opts.roster));
  const clubCount = directoryRows(opts.roster).length;
  const ids: string[] = [];
  let created = false;

  for (let i = 0; i < messages.length; i++) {
    const payload = {
      username: "GPSL Club Directory",
      allowed_mentions: { parse: [] as string[] },
      embeds: messages[i],
    };
    const existingId = opts.existingMessageIds[i];
    if (existingId) {
      const edited = await discordFetch(`${parsed.base}/messages/${existingId}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (edited.ok) {
        ids.push(existingId);
        continue;
      }
      if (edited.status !== 404) {
        return {
          ok: false,
          action: "error",
          message_ids: opts.existingMessageIds,
          error: `Discord edit ${edited.status}: ${edited.text.slice(0, 300)}`,
        };
      }
    }
    const posted = await discordFetch(`${parsed.base}?wait=true`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const newId = String(posted.json.id || "");
    if (!posted.ok || !newId) {
      return {
        ok: false,
        action: "error",
        message_ids: [...ids, ...opts.existingMessageIds.slice(i)],
        error: `Discord create ${posted.status}: ${posted.text.slice(0, 300)}`,
      };
    }
    ids.push(newId);
    created = true;
  }

  for (const staleId of opts.existingMessageIds.slice(messages.length)) {
    await discordFetch(`${parsed.base}/messages/${staleId}`, { method: "DELETE" });
  }

  return {
    ok: true,
    action: created ? "created" : "edited",
    message_ids: ids,
    club_count: clubCount,
  };
}
