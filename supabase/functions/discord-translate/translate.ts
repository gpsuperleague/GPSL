// DeepL (preferred) or Google Translate, with Discord mentions / emoji / links /
// inline code kept untranslated.

export type Language = { code: string; name: string; english: string };

export const LANGUAGES: Language[] = [
  { code: "AR", name: "العربية", english: "Arabic" },
  { code: "BG", name: "Български", english: "Bulgarian" },
  { code: "CS", name: "Čeština", english: "Czech" },
  { code: "DA", name: "Dansk", english: "Danish" },
  { code: "DE", name: "Deutsch", english: "German" },
  { code: "EL", name: "Ελληνικά", english: "Greek" },
  { code: "ES", name: "Español", english: "Spanish" },
  { code: "ET", name: "Eesti", english: "Estonian" },
  { code: "FI", name: "Suomi", english: "Finnish" },
  { code: "FR", name: "Français", english: "French" },
  { code: "HU", name: "Magyar", english: "Hungarian" },
  { code: "ID", name: "Bahasa Indonesia", english: "Indonesian" },
  { code: "IT", name: "Italiano", english: "Italian" },
  { code: "JA", name: "日本語", english: "Japanese" },
  { code: "KO", name: "한국어", english: "Korean" },
  { code: "LT", name: "Lietuvių", english: "Lithuanian" },
  { code: "LV", name: "Latviešu", english: "Latvian" },
  { code: "NB", name: "Norsk", english: "Norwegian" },
  { code: "NL", name: "Nederlands", english: "Dutch" },
  { code: "PL", name: "Polski", english: "Polish" },
  { code: "PT-BR", name: "Português (Brasil)", english: "Portuguese (Brazil)" },
  { code: "PT-PT", name: "Português (Portugal)", english: "Portuguese (Portugal)" },
  { code: "RO", name: "Română", english: "Romanian" },
  { code: "RU", name: "Русский", english: "Russian" },
  { code: "SK", name: "Slovenčina", english: "Slovak" },
  { code: "SL", name: "Slovenščina", english: "Slovenian" },
  { code: "SV", name: "Svenska", english: "Swedish" },
  { code: "TR", name: "Türkçe", english: "Turkish" },
  { code: "UK", name: "Українська", english: "Ukrainian" },
  { code: "ZH", name: "中文 (简体)", english: "Chinese (Simplified)" },
];

export const OFF_VALUE = "OFF";

export function languageLabel(code: string | null | undefined): string {
  if (!code) return "English";
  if (code === "EN-GB" || code === "EN") return "English";
  const l = LANGUAGES.find((x) => x.code === code);
  return l ? `${l.name} (${l.english})` : code;
}

/** Code from a choice value or free text ("es", "Español", "spanish"); null = off. */
export function normalizeLanguage(raw: string): string | null | undefined {
  const v = String(raw || "").trim();
  if (!v) return undefined;
  const up = v.toUpperCase();
  if (["OFF", "EN", "EN-GB", "EN-US", "ENGLISH", "NONE"].includes(up)) return null;
  const alias: Record<string, string> = { PT: "PT-PT", NO: "NB", "ZH-CN": "ZH", "ZH-HANS": "ZH" };
  const code = alias[up] || up;
  if (LANGUAGES.some((l) => l.code === code)) return code;
  const low = v.toLowerCase();
  const byName = LANGUAGES.find(
    (l) => l.name.toLowerCase() === low || l.english.toLowerCase() === low
  );
  return byName ? byName.code : undefined;
}

export function searchLanguages(query: string): Language[] {
  const q = String(query || "").trim().toLowerCase();
  if (!q) return LANGUAGES;
  return LANGUAGES.filter(
    (l) =>
      l.code.toLowerCase().startsWith(q) ||
      l.name.toLowerCase().includes(q) ||
      l.english.toLowerCase().includes(q)
  );
}

const TOKEN_RE =
  /<a?:\w+:\d+>|<[@#][!&]?\d+>|<t:\d+(?::[a-zA-Z])?>|https?:\/\/[^\s<>]+|`[^`\n]+`/g;

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function unesc(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&amp;/g, "&");
}

function protect(text: string, open: string, close: string, br: string): string {
  let out = "";
  let last = 0;
  for (const m of text.matchAll(TOKEN_RE)) {
    const idx = m.index ?? 0;
    out += esc(text.slice(last, idx)) + open + esc(m[0]) + close;
    last = idx + m[0].length;
  }
  out += esc(text.slice(last));
  return out.replace(/\r?\n/g, br);
}

function unprotect(text: string): string {
  return unesc(
    text
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/?x>/g, "")
      .replace(/<span (?:translate="no"|class="notranslate")>|<\/span>/g, "")
  );
}

function googleCode(code: string): string {
  const map: Record<string, string> = {
    "PT-BR": "pt",
    "PT-PT": "pt-PT",
    ZH: "zh-CN",
    NB: "no",
    "EN-GB": "en",
  };
  return map[code] || code.toLowerCase();
}

export type TranslateResult = { texts: string[]; detected: string | null };

async function deepl(key: string, texts: string[], target: string): Promise<TranslateResult> {
  const host = key.endsWith(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com";
  const res = await fetch(`${host}/v2/translate`, {
    method: "POST",
    headers: {
      Authorization: `DeepL-Auth-Key ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      text: texts.map((t) => protect(t, "<x>", "</x>", "<br/>")),
      target_lang: target,
      tag_handling: "xml",
      ignore_tags: ["x"],
      preserve_formatting: true,
    }),
  });
  if (!res.ok) {
    throw new Error(`DeepL ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const data = (await res.json()) as {
    translations?: { text: string; detected_source_language?: string }[];
  };
  const list = data.translations || [];
  return {
    texts: list.map((t) => unprotect(t.text)),
    detected: list[0]?.detected_source_language || null,
  };
}

async function google(key: string, texts: string[], target: string): Promise<TranslateResult> {
  const res = await fetch(
    `https://translation.googleapis.com/language/translate/v2?key=${encodeURIComponent(key)}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        q: texts.map((t) => protect(t, '<span translate="no">', "</span>", "<br>")),
        target: googleCode(target),
        format: "html",
      }),
    }
  );
  if (!res.ok) {
    throw new Error(`Google Translate ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const data = (await res.json()) as {
    data?: { translations?: { translatedText: string; detectedSourceLanguage?: string }[] };
  };
  const list = data.data?.translations || [];
  return {
    texts: list.map((t) => unprotect(t.translatedText)),
    detected: list[0]?.detectedSourceLanguage?.toUpperCase() || null,
  };
}

function azureCode(code: string): string {
  const map: Record<string, string> = {
    "PT-BR": "pt",
    "PT-PT": "pt-pt",
    ZH: "zh-Hans",
    "EN-GB": "en",
  };
  return map[code] || code.toLowerCase();
}

async function azure(
  key: string,
  region: string,
  texts: string[],
  target: string
): Promise<TranslateResult> {
  const headers: Record<string, string> = {
    "Ocp-Apim-Subscription-Key": key,
    "Content-Type": "application/json",
  };
  if (region) headers["Ocp-Apim-Subscription-Region"] = region;
  const res = await fetch(
    `https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&textType=html&to=${encodeURIComponent(azureCode(target))}`,
    {
      method: "POST",
      headers,
      body: JSON.stringify(
        texts.map((t) => ({ Text: protect(t, '<span class="notranslate">', "</span>", "<br>") }))
      ),
    }
  );
  if (!res.ok) {
    throw new Error(`Microsoft Translator ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const data = (await res.json()) as {
    detectedLanguage?: { language?: string };
    translations?: { text: string }[];
  }[];
  return {
    texts: data.map((d) => unprotect(d.translations?.[0]?.text || "")),
    detected: data[0]?.detectedLanguage?.language?.toUpperCase() || null,
  };
}

export function translationConfigured(): boolean {
  return Boolean(
    Deno.env.get("AZURE_TRANSLATOR_KEY") ||
      Deno.env.get("DEEPL_API_KEY") ||
      Deno.env.get("GOOGLE_TRANSLATE_API_KEY")
  );
}

/**
 * target: a LANGUAGES code, or "EN-GB" for English.
 * Order: Microsoft (free 2M chars/month) → DeepL → Google; falls through on errors
 * (e.g. monthly quota used up).
 */
export async function translateTexts(texts: string[], target: string): Promise<TranslateResult> {
  const providers: (() => Promise<TranslateResult>)[] = [];
  const azureKey = Deno.env.get("AZURE_TRANSLATOR_KEY") || "";
  if (azureKey) {
    const region = Deno.env.get("AZURE_TRANSLATOR_REGION") || "";
    providers.push(() => azure(azureKey, region, texts, target));
  }
  const deeplKey = Deno.env.get("DEEPL_API_KEY") || "";
  if (deeplKey) providers.push(() => deepl(deeplKey, texts, target));
  const googleKey = Deno.env.get("GOOGLE_TRANSLATE_API_KEY") || "";
  if (googleKey) providers.push(() => google(googleKey, texts, target));

  if (!providers.length) {
    throw new Error("No translation key — set AZURE_TRANSLATOR_KEY (or DEEPL_API_KEY / GOOGLE_TRANSLATE_API_KEY)");
  }

  let lastErr: unknown = null;
  for (const run of providers) {
    try {
      return await run();
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}
