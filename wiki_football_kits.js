/**
 * Wikipedia football-kit templates are CSS composites (arms/body/shorts/socks),
 * not single PNGs. Parse layer stacks and composite into kit images.
 */

export const WIKI_KIT_WIDTH = 100;
export const WIKI_KIT_HEIGHT = 135;
export const WIKI_KIT_SCALE = 4; // 400×540 output

const WIKI_UA = "GPSL-KitSync/1.0 (GPSL league; wiki kit composite)";

/** @typedef {{ bg: string|null, left: number, top: number, w: number, h: number, img: string|null }} WikiKitLayer */
/** @typedef {{ kind: 'home'|'away'|'third', label: string, layers: WikiKitLayer[] }} WikiKitStack */

export function wikiTitleFromUrlOrName(input) {
  const raw = String(input || "").trim();
  if (!raw) return null;
  const m = raw.match(/wikipedia\.org\/wiki\/([^?#]+)/i);
  if (m) return decodeURIComponent(m[1].replace(/_/g, " "));
  return raw.replace(/_/g, " ");
}

export function absoluteWikiImageUrl(src) {
  if (!src) return null;
  let u = String(src).split("?")[0];
  if (u.startsWith("//")) u = `https:${u}`;
  if (u.startsWith("http://")) u = `https://${u.slice(7)}`;
  return u;
}

/**
 * @param {string} html
 * @returns {WikiKitStack[]}
 */
export function parseWikipediaKitStacks(html) {
  const text = String(html || "");
  const exact =
    "position: relative; left: 0px; top: 0px; width: 100px; height: 135px; margin: 0 auto; padding: 0;";
  const starts = [];
  let from = 0;
  while (from < text.length) {
    const pos = text.indexOf(exact, from);
    if (pos < 0) break;
    starts.push(pos);
    from = pos + exact.length;
  }

  const stacks = [];
  for (let i = 0; i < starts.length; i += 1) {
    const pos = starts[i];
    const openAt = text.lastIndexOf("<div", pos);
    const regionEnd =
      i + 1 < starts.length ? starts[i + 1] : Math.min(text.length, pos + 12000);
    const region = text.slice(openAt >= 0 ? openAt : pos, regionEnd);

    const home = region.search(/>Home colours</i);
    const away = region.search(/>Away colours</i);
    const third = region.search(/>Third colours</i);
    const hits = [
      home >= 0 ? { kind: "home", label: "Home colours", at: home } : null,
      away >= 0 ? { kind: "away", label: "Away colours", at: away } : null,
      third >= 0 ? { kind: "third", label: "Third colours", at: third } : null,
    ].filter(Boolean);
    hits.sort((a, b) => a.at - b.at);
    if (!hits.length) continue;

    const kind = hits[0].kind;
    const label = hits[0].label;
    const block = region.slice(0, hits[0].at);
    const layers = parseAbsoluteLayers(block);
    if (layers.length) stacks.push({ kind, label, layers });
  }

  const seen = new Set();
  return stacks.filter((s) => {
    if (seen.has(s.kind)) return false;
    seen.add(s.kind);
    return true;
  });
}

/**
 * @param {string} block
 * @returns {WikiKitLayer[]}
 */
function parseAbsoluteLayers(block) {
  const layers = [];
  const re = /<div style="([^"]+)">([\s\S]*?)<\/div>/g;
  let m;
  while ((m = re.exec(block))) {
    const style = m[1];
    if (!/position:\s*absolute/i.test(style)) continue;
    const bgM = style.match(/background-color:\s*([^;]+)/i);
    const leftM = style.match(/left:\s*([-\d.]+)px/i);
    const topM = style.match(/top:\s*([-\d.]+)px/i);
    const wM = style.match(/width:\s*([-\d.]+)px/i);
    const hM = style.match(/height:\s*([-\d.]+)px/i);
    const imgM = m[2].match(/src="([^"]+)"/i);
    let bg = bgM ? bgM[1].trim() : null;
    if (bg && /inherit|transparent/i.test(bg)) bg = null;
    layers.push({
      bg,
      left: leftM ? Number(leftM[1]) : 0,
      top: topM ? Number(topM[1]) : 0,
      w: wM ? Number(wM[1]) : 0,
      h: hM ? Number(hM[1]) : 0,
      img: absoluteWikiImageUrl(imgM ? imgM[1] : null),
    });
  }
  return layers;
}

export async function fetchWikipediaParseHtml(pageTitle, fetchImpl = fetch) {
  const title = wikiTitleFromUrlOrName(pageTitle);
  if (!title) throw new Error("Wikipedia page title required");
  const url =
    "https://en.wikipedia.org/w/api.php?" +
    new URLSearchParams({
      action: "parse",
      page: title,
      prop: "text",
      format: "json",
      redirects: "1",
      origin: "*",
    }).toString();
  const res = await fetchImpl(url, { headers: { "User-Agent": WIKI_UA } });
  if (!res.ok) throw new Error(`Wikipedia parse failed (${res.status})`);
  const data = await res.json();
  if (data?.error?.info) throw new Error(data.error.info);
  const html = data?.parse?.text?.["*"];
  if (!html) throw new Error(`No HTML for Wikipedia page: ${title}`);
  return {
    title: data.parse.title || title,
    pageUrl: `https://en.wikipedia.org/wiki/${encodeURIComponent(
      String(data.parse.title || title).replace(/ /g, "_")
    )}`,
    html,
  };
}

function parseHexColor(color) {
  if (!color) return null;
  const c = String(color).trim();
  const hex = c.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (!hex) return null;
  let h = hex[1];
  if (h.length === 3) h = h.split("").map((ch) => ch + ch).join("");
  return {
    r: parseInt(h.slice(0, 2), 16),
    g: parseInt(h.slice(2, 4), 16),
    b: parseInt(h.slice(4, 6), 16),
    a: 255,
  };
}

/**
 * Composite one kit stack to PNG bytes using ImageScript.
 * @param {WikiKitStack} stack
 * @param {{ fetchImpl?: typeof fetch, Image: any, scale?: number }} opts
 */
export async function compositeWikiKitPng(stack, opts) {
  const Image = opts.Image;
  const fetchImpl = opts.fetchImpl || fetch;
  const scale = opts.scale || WIKI_KIT_SCALE;
  const W = Math.round(WIKI_KIT_WIDTH * scale);
  const H = Math.round(WIKI_KIT_HEIGHT * scale);
  const canvas = new Image(W, H);
  // transparent
  if (typeof canvas.fill === "function") {
    try {
      canvas.fill(typeof Image.rgbaToColor === "function"
        ? Image.rgbaToColor(0, 0, 0, 0)
        : 0x00000000);
    } catch {
      canvas.fill(0x00000000);
    }
  }

  for (const layer of stack.layers || []) {
    const x = Math.round(layer.left * scale);
    const y = Math.round(layer.top * scale);
    const lw = Math.max(1, Math.round(layer.w * scale));
    const lh = Math.max(1, Math.round(layer.h * scale));
    const rgba = parseHexColor(layer.bg);
    if (rgba) {
      const patch = new Image(lw, lh);
      const color =
        typeof Image.rgbaToColor === "function"
          ? Image.rgbaToColor(rgba.r, rgba.g, rgba.b, rgba.a)
          : ((rgba.r & 255) << 24) |
            ((rgba.g & 255) << 16) |
            ((rgba.b & 255) << 8) |
            (rgba.a & 255);
      patch.fill(color);
      canvas.composite(patch, x, y);
    }
    if (layer.img) {
      try {
        const imgRes = await fetchImpl(layer.img, {
          headers: { "User-Agent": WIKI_UA },
        });
        if (!imgRes.ok) continue;
        const bytes = new Uint8Array(await imgRes.arrayBuffer());
        let piece = await Image.decode(bytes);
        if (piece.width !== lw || piece.height !== lh) {
          piece = piece.resize(lw, lh);
        }
        canvas.composite(piece, x, y);
      } catch {
        /* skip broken layer */
      }
    }
  }

  return await canvas.encode();
}

/**
 * @param {string} pageTitleOrUrl
 * @param {{ fetchImpl?: typeof fetch, Image: any, scale?: number }} opts
 */
export async function fetchWikipediaKitPngs(pageTitleOrUrl, opts) {
  const parsed = await fetchWikipediaParseHtml(pageTitleOrUrl, opts.fetchImpl);
  const stacks = parseWikipediaKitStacks(parsed.html);
  if (!stacks.length) {
    return {
      ...parsed,
      kits: {},
      error: "No football-kit colours found on that Wikipedia page",
    };
  }

  /** @type {Record<string, { png: Uint8Array, label: string, layers: number }>} */
  const kits = {};
  for (const stack of stacks) {
    const png = await compositeWikiKitPng(stack, opts);
    kits[stack.kind] = {
      png,
      label: stack.label,
      layers: stack.layers.length,
    };
  }

  return {
    title: parsed.title,
    pageUrl: parsed.pageUrl,
    kits,
    error: null,
  };
}
