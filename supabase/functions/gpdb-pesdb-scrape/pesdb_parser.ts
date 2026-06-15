/** PESDB HTML parsers — server-rendered pages, no browser required. */

export const PLAYING_STYLES = [
  "Goal Poacher",
  "Dummy Runner",
  "Fox in the Box",
  "Prolific Winger",
  "Classic No. 10",
  "Hole Player",
  "Box-to-Box",
  "Anchor Man",
  "The Destroyer",
  "Extra Frontman",
  "Offensive Full-back",
  "Defensive Full-back",
  "Target Man",
  "Creative Playmaker",
  "Build Up",
  "Offensive Goalkeeper",
  "Defensive Goalkeeper",
  "Roaming Flank",
  "Cross Specialist",
  "Orchestrator",
  "Full-back Finisher",
  "Deep-Lying Forward",
];

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

export const PESDB_BASE = "https://pesdb.net/efootball/";

export function pesdbListUrl(page: number): string {
  if (page <= 1) return PESDB_BASE;
  return `${PESDB_BASE}?page=${page}`;
}

export function pesdbPlayerMaxUrl(playerId: string): string {
  return `${PESDB_BASE}?id=${encodeURIComponent(playerId)}&mode=max_level`;
}

export function decodeHtml(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .trim();
}

export function stripTags(html: string): string {
  return decodeHtml(html.replace(/<[^>]+>/g, " "));
}

export function detectPesdbTotals(html: string): {
  totalPlayers: number | null;
  maxPage: number | null;
} {
  const found = html.match(/\((\d+)\s+players found\)/i);
  const totalPlayers = found ? Number(found[1]) : null;

  const pageNums: number[] = [];
  for (const m of html.matchAll(/[?&]page=(\d+)/gi)) {
    const n = Number(m[1]);
    if (Number.isFinite(n)) pageNums.push(n);
  }

  const maxPage = pageNums.length ? Math.max(...pageNums) : null;
  return { totalPlayers, maxPage };
}

export type PesdbListRow = {
  konami_id: string;
  player_name: string;
  position: string;
  nationality: string;
  age: number;
  rating: number;
};

export function parsePesdbListPage(html: string): PesdbListRow[] {
  const tableMatch = html.match(/<table class="players">([\s\S]*?)<\/table>/i);
  if (!tableMatch) return [];

  const rows: PesdbListRow[] = [];
  const trRe = /<tr>([\s\S]*?)<\/tr>/gi;
  let trMatch: RegExpExecArray | null;

  while ((trMatch = trRe.exec(tableMatch[1])) !== null) {
    const rowHtml = trMatch[1];
    const tds = [...rowHtml.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((m) =>
      m[1]
    );
    if (tds.length < 8) continue;

    const posMatch =
      tds[0].match(/<div[^>]*title="([^"]+)"[^>]*>([^<]*)<\/div>/i) ||
      tds[0].match(/>([A-Z]{2,3})</);
    const position = decodeHtml(posMatch?.[2] || posMatch?.[1] || tds[0]).slice(
      0,
      8
    );

    const nameMatch = tds[1].match(/href="[^"]*\?id=([^"&]+)[^"]*"[^>]*>([^<]+)</i);
    if (!nameMatch) continue;

    const konami_id = decodeHtml(nameMatch[1]);
    const player_name = decodeHtml(nameMatch[2]);
    const nationality = stripTags(tds[3]);
    const age = Number(stripTags(tds[6]));
    const rating = Number(stripTags(tds[7]));

    if (!konami_id || !player_name) continue;

    rows.push({
      konami_id,
      player_name,
      position: position || "CF",
      nationality,
      age: Number.isFinite(age) ? age : 25,
      rating: Number.isFinite(rating) ? rating : 60,
    });
  }

  return rows;
}

export function parsePesdbMaxLevelPage(html: string): {
  max_level_rating: number | null;
  playing_style: string;
} {
  let max_level_rating: number | null = null;

  const overallBlock = html.match(
    /Overall Rating:[\s\S]{0,400}?<span[^>]*>(\d+)<\/span>/i
  );
  if (overallBlock) {
    max_level_rating = Number(overallBlock[1]);
  } else {
    const alt = html.match(/Overall Rating:[\s\S]{0,200}?\(\+\d+\)[^0-9]*(\d{2})/i);
    if (alt) max_level_rating = Number(alt[1]);
  }

  let playing_style = "None";
  const styleBlock = html.match(
    /<tr>\s*<th>\s*Playing Style\s*<\/th>\s*<\/tr>\s*<tr>\s*<td>([^<]+)<\/td>/i
  );
  if (styleBlock) {
    const candidate = decodeHtml(styleBlock[1]);
    if (PLAYING_STYLES.includes(candidate)) {
      playing_style = candidate;
    } else {
      for (const style of PLAYING_STYLES) {
        if (html.includes(`<td>${style}</td>`)) {
          playing_style = style;
          break;
        }
      }
    }
  }

  return {
    max_level_rating: Number.isFinite(max_level_rating) ? max_level_rating : null,
    playing_style,
  };
}

export async function fetchPesdbHtml(url: string): Promise<string> {
  const res = await fetch(url, {
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml",
    },
  });
  if (!res.ok) {
    throw new Error(`PESDB fetch failed (${res.status}): ${url}`);
  }
  return await res.text();
}

export async function mapWithConcurrency<T, R>(
  items: T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;

  async function worker() {
    while (true) {
      const i = next++;
      if (i >= items.length) break;
      out[i] = await fn(items[i], i);
    }
  }

  const workers = Array.from({ length: Math.min(limit, items.length) }, () =>
    worker()
  );
  await Promise.all(workers);
  return out;
}
