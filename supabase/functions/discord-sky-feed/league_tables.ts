/** League table PNG render + Discord #gpsl-tables publish */

export type StandingRow = {
  division?: string;
  club_name?: string;
  club_short_name?: string;
  table_position?: number;
  mp?: number;
  w?: number;
  d?: number;
  l?: number;
  gf?: number;
  ga?: number;
  gd?: number;
  pts?: number;
};

const DIVISIONS: { key: string; title: string }[] = [
  { key: "superleague", title: "SuperLeague" },
  { key: "championship_a", title: "Championship A" },
  { key: "championship_b", title: "Championship B" },
];

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function divisionTitle(key: string): string {
  return DIVISIONS.find((d) => d.key === key)?.title || key;
}

export function buildStandingsSvg(
  divisionKey: string,
  monthLabel: string,
  rows: StandingRow[]
): string {
  const title = divisionTitle(divisionKey);
  const sorted = [...rows].sort(
    (a, b) => (a.table_position || 99) - (b.table_position || 99)
  );
  const rowH = 28;
  const headerH = 86;
  const width = 720;
  const height = headerH + 32 + sorted.length * rowH + 24;

  const bodyRows = sorted
    .map((r, i) => {
      const y = headerH + 28 + i * rowH;
      const bg = i % 2 === 0 ? "#1a1a1a" : "#141414";
      const name = esc(
        String(r.club_name || r.club_short_name || "Club").slice(0, 28)
      );
      return `
      <rect x="24" y="${y - 20}" width="${width - 48}" height="${rowH}" fill="${bg}"/>
      <text x="40" y="${y}" fill="#ff9900" font-size="14" font-family="Segoe UI, Arial, sans-serif" font-weight="700">${r.table_position ?? i + 1}</text>
      <text x="78" y="${y}" fill="#eeeeee" font-size="14" font-family="Segoe UI, Arial, sans-serif">${name}</text>
      <text x="360" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.mp ?? 0}</text>
      <text x="410" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.w ?? 0}</text>
      <text x="450" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.d ?? 0}</text>
      <text x="490" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.l ?? 0}</text>
      <text x="545" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.gf ?? 0}</text>
      <text x="585" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.ga ?? 0}</text>
      <text x="630" y="${y}" fill="#cccccc" font-size="13" font-family="Consolas, monospace" text-anchor="end">${r.gd ?? 0}</text>
      <text x="680" y="${y}" fill="#ffffff" font-size="14" font-family="Consolas, monospace" font-weight="700" text-anchor="end">${r.pts ?? 0}</text>`;
    })
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  <rect width="100%" height="100%" fill="#111111"/>
  <text x="36" y="36" fill="#ff9900" font-size="22" font-family="Segoe UI, Arial, sans-serif" font-weight="700">GPSL ${esc(title)}</text>
  <text x="36" y="62" fill="#aaaaaa" font-size="14" font-family="Segoe UI, Arial, sans-serif">End of ${esc(monthLabel)} · League table</text>
  <text x="360" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">P</text>
  <text x="410" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">W</text>
  <text x="450" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">D</text>
  <text x="490" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">L</text>
  <text x="545" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">GF</text>
  <text x="585" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">GA</text>
  <text x="630" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">GD</text>
  <text x="680" y="${headerH}" fill="#888888" font-size="11" font-family="Consolas, monospace" text-anchor="end">PTS</text>
  ${bodyRows}
</svg>`;
}

export function standingsToCodeBlock(
  divisionKey: string,
  rows: StandingRow[]
): string {
  const sorted = [...rows].sort(
    (a, b) => (a.table_position || 99) - (b.table_position || 99)
  );
  const lines = [
    `${divisionTitle(divisionKey)}`,
    "Pos Club                         P   W   D   L  GF  GA  GD Pts",
    "-".repeat(58),
    ...sorted.map((r) => {
      const name = String(r.club_name || r.club_short_name || "Club").padEnd(
        26
      ).slice(0, 26);
      const n = (v: unknown, w: number) => String(v ?? 0).padStart(w);
      return `${n(r.table_position, 2)}  ${name} ${n(r.mp, 3)} ${n(r.w, 3)} ${n(r.d, 3)} ${n(r.l, 3)} ${n(r.gf, 3)} ${n(r.ga, 3)} ${n(r.gd, 3)} ${n(r.pts, 3)}`;
    }),
  ];
  return "```\n" + lines.join("\n").slice(0, 3900) + "\n```";
}

let wasmReady: Promise<void> | null = null;

async function ensureResvgWasm(): Promise<typeof import("npm:@resvg/resvg-wasm@2.6.2")> {
  const mod = await import("npm:@resvg/resvg-wasm@2.6.2");
  if (!wasmReady) {
    wasmReady = (async () => {
      const initWasm = mod.initWasm;
      if (typeof initWasm !== "function") return;
      try {
        // Explicit WASM URL — bare initWasm() often fails in Edge/Deno
        await initWasm(
          fetch(
            "https://cdn.jsdelivr.net/npm/@resvg/resvg-wasm@2.6.2/index_bg.wasm"
          )
        );
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (!/already initialized/i.test(msg)) throw err;
      }
    })();
  }
  await wasmReady;
  return mod;
}

export async function svgToPng(svg: string): Promise<Uint8Array | null> {
  try {
    const mod = await ensureResvgWasm();
    const resvg = new mod.Resvg(svg, {
      fitTo: { mode: "width", value: 720 },
    });
    const rendered = resvg.render();
    return rendered.asPng();
  } catch {
    return null;
  }
}

export async function publishLeagueTables(opts: {
  adminClient: {
    storage: {
      from: (bucket: string) => {
        upload: (
          path: string,
          body: Uint8Array,
          opts: Record<string, unknown>
        ) => Promise<{ error: { message: string } | null }>;
        getPublicUrl: (path: string) => { data: { publicUrl: string } };
      };
    };
  };
  supabaseUrl: string;
  tablesWebhookUrl: string;
  monthLabel: string;
  gpslMonth: string;
  seasonId: number | string;
  standings: StandingRow[];
  postWebhook: (
    url: string,
    embeds: Record<string, unknown>[],
    opts?: { username?: string }
  ) => Promise<void>;
}): Promise<{ ok: boolean; images: number; fallback_text: boolean; error?: string }> {
  const {
    adminClient,
    tablesWebhookUrl,
    monthLabel,
    gpslMonth,
    seasonId,
    standings,
    postWebhook,
  } = opts;

  const embeds: Record<string, unknown>[] = [];
  let images = 0;
  let usedText = false;

  for (const div of DIVISIONS) {
    const rows = standings.filter((r) => r.division === div.key);
    if (!rows.length) continue;

    const svg = buildStandingsSvg(div.key, monthLabel, rows);
    const png = await svgToPng(svg);
    const path = `${seasonId}/${gpslMonth}/${div.key}-${Date.now()}.png`;

    if (png) {
      const { error: upErr } = await adminClient.storage
        .from("league-tables")
        .upload(path, png, {
          contentType: "image/png",
          upsert: true,
        });
      if (!upErr) {
        const { data } = adminClient.storage
          .from("league-tables")
          .getPublicUrl(path);
        embeds.push({
          title: `📊 ${div.title} — ${monthLabel}`,
          color: 0x5865f2,
          image: { url: data.publicUrl },
          footer: { text: "GPSL Tables" },
          timestamp: new Date().toISOString(),
        });
        images += 1;
        continue;
      }
    }

    // Fallback: monospace table in embed description
    usedText = true;
    embeds.push({
      title: `📊 ${div.title} — ${monthLabel}`,
      description: standingsToCodeBlock(div.key, rows),
      color: 0x5865f2,
      footer: { text: "GPSL Tables (text fallback)" },
      timestamp: new Date().toISOString(),
    });
  }

  if (!embeds.length) {
    return { ok: false, images: 0, fallback_text: false, error: "no_standings_rows" };
  }

  await postWebhook(tablesWebhookUrl, embeds.slice(0, 10), {
    username: "GPSL Tables",
  });

  return { ok: true, images, fallback_text: usedText };
}
