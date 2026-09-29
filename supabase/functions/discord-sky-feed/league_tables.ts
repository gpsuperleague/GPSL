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

/** Edge/Deno has no system fonts — resvg needs an embedded TTF or text is invisible */
const FONT_FAMILY = "DejaVu Sans";
const FONT_URL =
  "https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf/DejaVuSans.ttf";
const FONT_BOLD_URL =
  "https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf/DejaVuSans-Bold.ttf";

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

// Zone rules mirror competition.js (prestigeCupForPosition / leagueTintKey / leagueBoundaryKey).
const CUP_BAR_COLORS: Record<string, string> = {
  super8: "#5a7db5",
  plate: "#c98652",
  shield: "#6d9f7a",
  bowl: "#c9a84c",
};

const ZONE_COLORS: Record<string, string> = {
  champion: "#c9a84c",
  runner_up: "#9ca3b8",
  promotion: "#6d9f7a",
  playoffs: "#9b87b8",
  playoff: "#c98652",
  relegation: "#b86a6a",
  bowl: "#b86a6a",
};

function isLeagueDivision(key: string): boolean {
  return DIVISIONS.some((d) => d.key === key);
}

function prestigeCupKey(division: string, pos: number): string | null {
  if (division === "superleague") {
    if (pos <= 8) return "super8";
    if (pos <= 16) return "plate";
    if (pos <= 20) return "shield";
    return null;
  }
  if (pos <= 4) return "plate";
  if (pos <= 15) return "shield";
  if (pos >= 18) return "bowl";
  return null;
}

function zoneTintKey(division: string, pos: number): string | null {
  if (division === "superleague") {
    if (pos === 1) return "champion";
    if (pos === 2) return "runner_up";
    if (pos >= 18) return "relegation";
    if (pos >= 16) return "playoff";
    return null;
  }
  if (pos <= 2) return "promotion";
  if (pos <= 6) return "playoffs";
  if (pos >= 18) return "bowl";
  if (pos >= 16) return "playoff";
  return null;
}

function zoneBoundaryKey(division: string, pos: number): string {
  if (division === "superleague") {
    if (pos >= 18) return "relegation";
    if (pos >= 16) return "playoff";
    return "safe";
  }
  if (pos <= 2) return "promotion";
  if (pos <= 6) return "playoffs";
  if (pos >= 18) return "bowl";
  if (pos >= 16) return "playoff";
  return "safe";
}

function zoneLegend(division: string): { zones: [string, string][]; cups: [string, string][] } {
  if (division === "superleague") {
    return {
      zones: [
        ["champion", "Champion"],
        ["runner_up", "Runner-up"],
        ["playoff", "Relegation playoff (16–17)"],
        ["relegation", "Relegation (18+)"],
      ],
      cups: [
        ["super8", "Super8 (1–8)"],
        ["plate", "Plate (9–16)"],
        ["shield", "Shield (17–20)"],
      ],
    };
  }
  return {
    zones: [
      ["promotion", "Promotion (1–2)"],
      ["playoffs", "Promotion playoffs (3–6)"],
      ["playoff", "Shield/Bowl playoff (16–17)"],
      ["bowl", "Bowl (18+)"],
    ],
    cups: [
      ["plate", "Plate (1–4)"],
      ["shield", "Shield (5–15)"],
      ["bowl", "Bowl (18+)"],
    ],
  };
}

function legendRowSvg(
  y: number,
  heading: string,
  items: [string, string][],
  colors: Record<string, string>
): string {
  let x = 36;
  let out = `<text x="${x}" y="${y}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" font-weight="700">${esc(heading)}</text>`;
  x += heading.length * 7 + 12;
  for (const [key, label] of items) {
    out += `<rect x="${x}" y="${y - 10}" width="12" height="12" rx="2" fill="${colors[key] || "#666"}"/>`;
    out += `<text x="${x + 17}" y="${y}" fill="#bbbbbb" font-size="11" font-family="${FONT_FAMILY}">${esc(label)}</text>`;
    x += 17 + label.length * 6.4 + 16;
  }
  return out;
}

export function buildStandingsSvg(
  divisionKey: string,
  monthLabel: string,
  rows: StandingRow[],
  opts?: {
    subtitle?: string;
    highlightClub?: string | null;
    titleOverride?: string | null;
  }
): string {
  const title = opts?.titleOverride || divisionTitle(divisionKey);
  const subtitle = opts?.subtitle || `End of ${monthLabel} · League table`;
  const highlight = String(opts?.highlightClub || "").toLowerCase();
  const sorted = [...rows].sort(
    (a, b) => (a.table_position || 99) - (b.table_position || 99)
  );
  const rowH = 28;
  const headerH = 86;
  const width = 720;
  const zones = isLeagueDivision(divisionKey);
  const legendH = zones ? 58 : 0;
  const tableBottom = headerH + 32 + sorted.length * rowH;
  const height = tableBottom + 24 + legendH;
  const posOf = (r: StandingRow, i: number) => Number(r.table_position ?? i + 1);

  const bodyRows = sorted
    .map((r, i) => {
      const y = headerH + 28 + i * rowH;
      const pos = posOf(r, i);
      const isHi =
        highlight &&
        String(r.club_short_name || "").toLowerCase() === highlight;
      const bg = isHi ? "#2a2208" : i % 2 === 0 ? "#1a1a1a" : "#141414";
      const name = esc(
        String(r.club_name || r.club_short_name || "Club").slice(0, 28)
      );
      let zoneSvg = "";
      if (zones) {
        const tint = zoneTintKey(divisionKey, pos);
        if (tint) {
          zoneSvg += `<rect x="24" y="${y - 20}" width="${width - 48}" height="${rowH}" fill="${ZONE_COLORS[tint]}" fill-opacity="0.16"/>`;
        }
        const cup = prestigeCupKey(divisionKey, pos);
        if (cup) {
          zoneSvg += `<rect x="24" y="${y - 20}" width="6" height="${rowH}" fill="${CUP_BAR_COLORS[cup]}"/>`;
        }
        if (i > 0) {
          const prevKey = zoneBoundaryKey(divisionKey, posOf(sorted[i - 1], i - 1));
          const key = zoneBoundaryKey(divisionKey, pos);
          if (prevKey !== key) {
            const lineKey = key !== "safe" ? key : prevKey;
            const dashed = lineKey === "playoff" || lineKey === "playoffs";
            zoneSvg += `<line x1="24" y1="${y - 20}" x2="${width - 24}" y2="${y - 20}" stroke="${ZONE_COLORS[lineKey]}" stroke-width="2"${dashed ? ' stroke-dasharray="7 5"' : ""}/>`;
          }
        }
      }
      return `
      <rect x="24" y="${y - 20}" width="${width - 48}" height="${rowH}" fill="${bg}"/>
      ${zoneSvg}
      <text x="40" y="${y}" fill="#ff9900" font-size="14" font-family="${FONT_FAMILY}" font-weight="700">${r.table_position ?? i + 1}</text>
      <text x="78" y="${y}" fill="${isHi ? "#ffcc66" : "#eeeeee"}" font-size="14" font-family="${FONT_FAMILY}"${isHi ? ' font-weight="700"' : ""}>${name}</text>
      <text x="360" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.mp ?? 0}</text>
      <text x="410" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.w ?? 0}</text>
      <text x="450" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.d ?? 0}</text>
      <text x="490" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.l ?? 0}</text>
      <text x="545" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.gf ?? 0}</text>
      <text x="585" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.ga ?? 0}</text>
      <text x="630" y="${y}" fill="#cccccc" font-size="13" font-family="${FONT_FAMILY}" text-anchor="end">${r.gd ?? 0}</text>
      <text x="680" y="${y}" fill="#ffffff" font-size="14" font-family="${FONT_FAMILY}" font-weight="700" text-anchor="end">${r.pts ?? 0}</text>`;
    })
    .join("\n");

  let legendSvg = "";
  if (zones) {
    const legend = zoneLegend(divisionKey);
    const ly = tableBottom + 26;
    legendSvg =
      legendRowSvg(ly, "League", legend.zones, ZONE_COLORS) +
      legendRowSvg(ly + 22, "Cup bar", legend.cups, CUP_BAR_COLORS);
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  <rect width="100%" height="100%" fill="#111111"/>
  <text x="36" y="36" fill="#ff9900" font-size="22" font-family="${FONT_FAMILY}" font-weight="700">GPSL ${esc(title)}</text>
  <text x="36" y="62" fill="#aaaaaa" font-size="14" font-family="${FONT_FAMILY}">${esc(subtitle)}</text>
  <text x="360" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">P</text>
  <text x="410" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">W</text>
  <text x="450" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">D</text>
  <text x="490" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">L</text>
  <text x="545" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">GF</text>
  <text x="585" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">GA</text>
  <text x="630" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">GD</text>
  <text x="680" y="${headerH}" fill="#888888" font-size="11" font-family="${FONT_FAMILY}" text-anchor="end">PTS</text>
  ${bodyRows}
  ${legendSvg}
</svg>`;
}

export function standingsToCodeBlock(
  divisionKey: string,
  rows: StandingRow[],
  titleOverride?: string | null
): string {
  const sorted = [...rows].sort(
    (a, b) => (a.table_position || 99) - (b.table_position || 99)
  );
  const zones = isLeagueDivision(divisionKey);
  const marks: Record<string, string> = {
    champion: "★",
    runner_up: "▲",
    promotion: "▲",
    playoffs: "◆",
    playoff: "◇",
    relegation: "▼",
    bowl: "▼",
  };
  const lines = [
    titleOverride || divisionTitle(divisionKey),
    "  Pos Club                         P   W   D   L  GF  GA  GD Pts",
    "-".repeat(60),
  ];
  sorted.forEach((r, i) => {
    const pos = Number(r.table_position ?? i + 1);
    if (zones && i > 0) {
      const prev = zoneBoundaryKey(divisionKey, Number(sorted[i - 1].table_position ?? i));
      const cur = zoneBoundaryKey(divisionKey, pos);
      if (prev !== cur) {
        const key = cur !== "safe" ? cur : prev;
        lines.push(key === "playoff" || key === "playoffs" ? "- ".repeat(30) : "=".repeat(60));
      }
    }
    const tint = zones ? zoneTintKey(divisionKey, pos) : null;
    const mark = tint ? marks[tint] : " ";
    const name = String(r.club_name || r.club_short_name || "Club").padEnd(26).slice(0, 26);
    const n = (v: unknown, w: number) => String(v ?? 0).padStart(w);
    lines.push(
      `${mark} ${n(r.table_position, 2)}  ${name} ${n(r.mp, 3)} ${n(r.w, 3)} ${n(r.d, 3)} ${n(r.l, 3)} ${n(r.gf, 3)} ${n(r.ga, 3)} ${n(r.gd, 3)} ${n(r.pts, 3)}`
    );
  });
  if (zones) {
    lines.push(
      "",
      divisionKey === "superleague"
        ? "★ Champion  ▲ Runner-up  ◇ Relegation playoff  ▼ Relegated"
        : "▲ Promotion  ◆ Promotion playoffs  ◇ Shield/Bowl playoff  ▼ Bowl"
    );
  }
  return "```\n" + lines.join("\n").slice(0, 3900) + "\n```";
}

let wasmReady: Promise<void> | null = null;
let fontBuffersPromise: Promise<Uint8Array[]> | null = null;

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

async function loadFontBuffers(): Promise<Uint8Array[]> {
  if (!fontBuffersPromise) {
    fontBuffersPromise = (async () => {
      const out: Uint8Array[] = [];
      for (const url of [FONT_URL, FONT_BOLD_URL]) {
        const res = await fetch(url);
        if (!res.ok) continue;
        out.push(new Uint8Array(await res.arrayBuffer()));
      }
      if (!out.length) {
        throw new Error("Could not load fonts for league table PNG render");
      }
      return out;
    })();
  }
  return fontBuffersPromise;
}

export async function svgToPng(svg: string): Promise<Uint8Array | null> {
  try {
    const mod = await ensureResvgWasm();
    const fontBuffers = await loadFontBuffers();
    const resvg = new mod.Resvg(svg, {
      fitTo: { mode: "width", value: 720 },
      font: {
        fontBuffers,
        defaultFontFamily: FONT_FAMILY,
        defaultFontWeight: 400,
        loadSystemFonts: false,
      },
    });
    const rendered = resvg.render();
    const png = rendered.asPng();
    // Tiny / empty-ish PNGs mean render failed silently — prefer text fallback
    if (!png || png.byteLength < 2000) return null;
    return png;
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
  highlightDivision?: string | null;
  highlightClub?: string | null;
  subtitle?: string | null;
  embedTitlePrefix?: string | null;
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
    highlightDivision,
    highlightClub,
    subtitle,
    embedTitlePrefix,
    postWebhook,
  } = opts;

  const embeds: Record<string, unknown>[] = [];
  let images = 0;
  let usedText = false;
  const onlyDiv = String(highlightDivision || "").toLowerCase();
  const divisions = onlyDiv
    ? DIVISIONS.filter((d) => d.key === onlyDiv)
    : DIVISIONS;

  for (const div of divisions) {
    const rows = standings.filter((r) => r.division === div.key);
    if (!rows.length) continue;

    const svg = buildStandingsSvg(div.key, monthLabel, rows, {
      subtitle: subtitle || undefined,
      highlightClub: highlightClub || undefined,
    });
    const png = await svgToPng(svg);
    const path = `${seasonId}/${gpslMonth}/${div.key}-${Date.now()}.png`;
    const title = embedTitlePrefix
      ? `${embedTitlePrefix}`
      : `📊 ${div.title} — ${monthLabel}`;

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
          title: title.slice(0, 250),
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
      title: title.slice(0, 250),
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

export type IntlTableGroup = {
  table_key?: string;
  title?: string;
  phase?: string;
  group_code?: string;
  standings?: StandingRow[];
};

export async function publishIntlTables(opts: {
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
  tablesWebhookUrl: string;
  monthLabel: string;
  gpslMonth: string;
  seasonId: number | string;
  cycleLabel?: string | null;
  groups: IntlTableGroup[];
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
    cycleLabel,
    groups,
    postWebhook,
  } = opts;

  const embeds: Record<string, unknown>[] = [];
  let images = 0;
  let usedText = false;
  const cycle = String(cycleLabel || "World Cup");

  for (const g of groups || []) {
    const rows = Array.isArray(g.standings) ? g.standings : [];
    if (!rows.length) continue;

    const tableKey = String(g.table_key || g.group_code || "group");
    const title = String(
      g.title || `WC Group ${g.group_code || tableKey}`
    ).slice(0, 250);
    const svg = buildStandingsSvg(tableKey, monthLabel, rows, {
      titleOverride: title,
      subtitle: `${cycle} · End of ${monthLabel}`,
    });
    const png = await svgToPng(svg);
    const path = `intl/${seasonId}/${gpslMonth}/${tableKey.replace(/[^a-zA-Z0-9_-]/g, "_")}-${Date.now()}.png`;

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
          title,
          color: 0x9b59b6,
          image: { url: data.publicUrl },
          footer: { text: "GPSL Intl Tables" },
          timestamp: new Date().toISOString(),
        });
        images += 1;
        continue;
      }
    }

    usedText = true;
    embeds.push({
      title,
      description: standingsToCodeBlock(tableKey, rows, title),
      color: 0x9b59b6,
      footer: { text: "GPSL Intl Tables (text fallback)" },
      timestamp: new Date().toISOString(),
    });
  }

  if (!embeds.length) {
    return {
      ok: false,
      images: 0,
      fallback_text: false,
      error: "no_intl_standings_rows",
    };
  }

  // Discord allows max 10 embeds per message — batch
  for (let i = 0; i < embeds.length; i += 10) {
    await postWebhook(tablesWebhookUrl, embeds.slice(i, i + 10), {
      username: "GPSL Intl Tables",
    });
    if (i + 10 < embeds.length) {
      await new Promise((r) => setTimeout(r, 700));
    }
  }

  return { ok: true, images, fallback_text: usedText };
}
