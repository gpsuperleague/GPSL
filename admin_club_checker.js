/**
 * Admin club checker — freeform StadiumDB + COF + Wikipedia lookup.
 */
import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260816-club-checker";

primeAdminPageChrome();

const STADIUM_FN = "club-stadiums-sync";
const KITS_FN = "club-kits-cof-sync";

/** @type {{ title: string, url: string } | null} */
let lastWikiHit = null;
/** @type {Record<string, { data_url?: string, image_base64?: string }> | null} */
let lastWikiKits = null;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function setCardStatus(id, text, state) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.classList.remove("is-ok", "is-err", "is-loading");
  if (state) el.classList.add(`is-${state}`);
}

function formValues() {
  return {
    clubName: document.getElementById("clubName")?.value?.trim() || "",
    stadiumName: document.getElementById("stadiumName")?.value?.trim() || "",
    nationName: document.getElementById("nationName")?.value?.trim() || "",
    clubShort: (document.getElementById("clubShort")?.value || "")
      .trim()
      .toUpperCase(),
  };
}

function setWikiKitButtons({ extractEnabled, saveEnabled }) {
  const extractBtn = document.getElementById("wikiKitsBtn");
  const saveBtn = document.getElementById("saveWikiKitsBtn");
  if (extractBtn) extractBtn.disabled = !extractEnabled;
  if (saveBtn) saveBtn.disabled = !saveEnabled;
}

async function invokeFn(name, body) {
  const { data, error } = await supabase.functions.invoke(name, { body });
  if (!error) {
    if (data?.error && !data?.page_url && !data?.result && !data?.ok) {
      throw new Error(String(data.error));
    }
    return data;
  }

  let detail = error.message || `${name} request failed`;
  try {
    const ctx = error.context;
    if (ctx && typeof ctx.json === "function") {
      const payload = await ctx.json();
      if (payload?.error) detail = String(payload.error);
    }
  } catch (_) {
    /* ignore */
  }
  if (data?.error) detail = String(data.error);
  if (/unknown action:\s*preview_freeform/i.test(detail)) {
    detail =
      `${name} is still the old deploy (no preview_freeform). Paste updated index.ts in Supabase → Deploy (JWT OFF).`;
  } else if (/failed to send|cors|520|502/i.test(detail)) {
    detail += ` — deploy ${name} (paste index.ts), JWT verify OFF, then retry.`;
  }
  throw new Error(detail);
}

async function lookupStadium({ clubName, stadiumName, nationName }) {
  return invokeFn(STADIUM_FN, {
    action: "preview_freeform",
    club_name: clubName,
    stadium: stadiumName,
    nation: nationName,
  });
}

async function lookupKits({ clubName, nationName }) {
  return invokeFn(KITS_FN, {
    action: "preview_freeform",
    club_name: clubName,
    nation: nationName,
  });
}

async function lookupWikipedia({ clubName }) {
  const url = new URL("https://en.wikipedia.org/w/api.php");
  url.searchParams.set("action", "opensearch");
  url.searchParams.set("search", clubName);
  url.searchParams.set("limit", "1");
  url.searchParams.set("namespace", "0");
  url.searchParams.set("format", "json");
  url.searchParams.set("origin", "*");

  const res = await fetch(url.toString());
  if (!res.ok) throw new Error(`Wikipedia search failed (${res.status})`);
  const data = await res.json();
  const title = data?.[1]?.[0];
  const pageUrl = data?.[3]?.[0];
  const description = data?.[2]?.[0] || "";
  if (!title || !pageUrl) return null;
  return { title, url: pageUrl, description };
}

function renderStadium(data, err) {
  const meta = document.getElementById("stadiumMeta");
  const preview = document.getElementById("stadiumPreview");
  meta.innerHTML = "";
  preview.innerHTML = "";

  if (err) {
    setCardStatus("stadiumStatus", err.message || String(err), "err");
    return;
  }

  if (data?.error) {
    setCardStatus("stadiumStatus", data.error, "err");
  } else {
    setCardStatus("stadiumStatus", "Found", "ok");
  }

  const parts = [];
  if (data?.page_url) {
    parts.push(
      `Page: <a href="${escapeHtml(data.page_url)}" target="_blank" rel="noopener">${escapeHtml(data.page_url)}</a>`
    );
  }
  if (data?.image_url) {
    parts.push(
      `Image: <a href="${escapeHtml(data.image_url)}" target="_blank" rel="noopener">${escapeHtml(data.image_url)}</a>`
    );
  }
  meta.innerHTML = parts.join("<br>") || "No StadiumDB match.";

  if (data?.image_url) {
    preview.innerHTML = `
      <figure>
        <img src="${escapeHtml(data.image_url)}" alt="Stadium preview" loading="lazy">
        <figcaption>Stadium</figcaption>
      </figure>`;
  }
}

function renderKits(data, err) {
  const meta = document.getElementById("kitsMeta");
  const preview = document.getElementById("kitsPreview");
  meta.innerHTML = "";
  preview.innerHTML = "";

  if (err) {
    setCardStatus("kitsStatus", err.message || String(err), "err");
    return;
  }

  const result = data?.result || {};
  if (result.error || data?.error) {
    setCardStatus("kitsStatus", result.error || data.error, "err");
  } else {
    setCardStatus("kitsStatus", "Found", "ok");
  }

  const season = result.seasonLabel || result.latestSeasonCode || "—";
  const cofName = result.cofClubName || result.slug || "—";
  const indexUrl = result.indexUrl
    ? `<a href="${escapeHtml(result.indexUrl)}" target="_blank" rel="noopener">nation index</a>`
    : "";
  const clubPage =
    result.nationFolder && result.slug && result.pageStem
      ? `https://www.colours-of-football.com/colours03/${result.nationFolder}/${result.slug}/${result.pageStem}_1.html`
      : null;

  meta.innerHTML = [
    `Match: <b>${escapeHtml(cofName)}</b> · season ${escapeHtml(season)}`,
    clubPage
      ? `Club page: <a href="${escapeHtml(clubPage)}" target="_blank" rel="noopener">${escapeHtml(clubPage)}</a>`
      : "",
    indexUrl,
  ]
    .filter(Boolean)
    .join("<br>");

  const kits = result.kits || {};
  const figures = ["home", "away", "third"]
    .filter((kind) => kits[kind])
    .map(
      (kind) => `
      <figure>
        <img src="${escapeHtml(kits[kind])}" alt="${kind} kit" loading="lazy">
        <figcaption>${kind}</figcaption>
      </figure>`
    )
    .join("");
  preview.innerHTML = figures || "<span style='color:#777;font-size:12px;'>No kit images.</span>";
}

function renderWiki(hit, err) {
  const meta = document.getElementById("wikiMeta");
  const list = document.getElementById("wikiList");
  const kitsPreview = document.getElementById("wikiKitsPreview");
  const kitsMeta = document.getElementById("wikiKitsMeta");
  meta.innerHTML = "";
  list.innerHTML = "";
  if (kitsPreview) kitsPreview.innerHTML = "";
  if (kitsMeta) kitsMeta.innerHTML = "";
  lastWikiHit = null;
  lastWikiKits = null;
  setWikiKitButtons({ extractEnabled: false, saveEnabled: false });

  if (err) {
    setCardStatus("wikiStatus", err.message || String(err), "err");
    return;
  }

  if (!hit?.url) {
    setCardStatus("wikiStatus", "No Wikipedia page", "err");
    meta.textContent = "No page found for that club name.";
    return;
  }

  lastWikiHit = { title: hit.title, url: hit.url };
  setCardStatus("wikiStatus", "Found", "ok");
  meta.innerHTML = `Club page:
    <a href="${escapeHtml(hit.url)}" target="_blank" rel="noopener">${escapeHtml(hit.title)}</a>`;
  if (hit.description) {
    list.innerHTML = `<li><span class="wiki-snip">${escapeHtml(hit.description)}</span></li>`;
  }
  setWikiKitButtons({ extractEnabled: true, saveEnabled: false });
}

function renderWikiKitPreviews(data, err) {
  const preview = document.getElementById("wikiKitsPreview");
  const meta = document.getElementById("wikiKitsMeta");
  if (!preview || !meta) return;
  preview.innerHTML = "";
  meta.innerHTML = "";

  if (err) {
    meta.innerHTML = `<span style="color:#f88;">${escapeHtml(err.message || String(err))}</span>`;
    lastWikiKits = null;
    setWikiKitButtons({
      extractEnabled: !!lastWikiHit,
      saveEnabled: false,
    });
    return;
  }

  if (data?.error) {
    meta.innerHTML = `<span style="color:#f88;">${escapeHtml(data.error)}</span>`;
    lastWikiKits = null;
    setWikiKitButtons({
      extractEnabled: !!lastWikiHit,
      saveEnabled: false,
    });
    return;
  }

  lastWikiKits = data?.kits || null;
  const kits = lastWikiKits || {};
  const figures = ["home", "away", "third"]
    .filter((kind) => kits[kind]?.data_url)
    .map(
      (kind) => `
      <figure>
        <img src="${escapeHtml(kits[kind].data_url)}" alt="Wiki ${kind} kit">
        <figcaption>wiki ${kind}</figcaption>
      </figure>`
    )
    .join("");
  preview.innerHTML =
    figures ||
    "<span style='color:#777;font-size:12px;'>No home/away/third kit templates on the page.</span>";
  meta.innerHTML = data?.page_url
    ? `Composited from Wikipedia kit templates (not a single photo). Source:
       <a href="${escapeHtml(data.page_url)}" target="_blank" rel="noopener">${escapeHtml(data.title || "page")}</a>`
    : "Composited from Wikipedia kit templates.";

  const short = formValues().clubShort;
  setWikiKitButtons({
    extractEnabled: !!lastWikiHit,
    saveEnabled: !!(lastWikiKits && Object.keys(lastWikiKits).length && short),
  });
}

async function extractWikipediaKits() {
  if (!lastWikiHit?.url) {
    setStatus("statusLine", "Run Lookup first to find the Wikipedia club page.", false);
    return;
  }
  setStatus("statusLine", "Compositing Wikipedia kits (home/away/third)…", true);
  setWikiKitButtons({ extractEnabled: false, saveEnabled: false });
  try {
    const data = await invokeFn(KITS_FN, {
      action: "preview_wikipedia_kits",
      wikipedia_url: lastWikiHit.url,
      wikipedia_title: lastWikiHit.title,
    });
    renderWikiKitPreviews(data, null);
    setStatus(
      "statusLine",
      data?.error
        ? data.error
        : "Wikipedia kits ready. Enter GPSL ShortName and Save to push PNGs.",
      !data?.error
    );
  } catch (err) {
    renderWikiKitPreviews(null, err);
    setStatus("statusLine", err.message || String(err), false);
  }
}

async function saveWikipediaKits() {
  const short = formValues().clubShort;
  if (!short) {
    setStatus(
      "statusLine",
      "Enter GPSL ShortName (club must exist) before saving kits.",
      false
    );
    return;
  }
  if (!lastWikiHit?.url) {
    setStatus("statusLine", "Run Lookup + Extract kits first.", false);
    return;
  }
  if (
    !window.confirm(
      `Composite Wikipedia kits and commit to images/clubs_kits/${short}_home|away|third.png on GitHub?`
    )
  ) {
    return;
  }
  setStatus("statusLine", `Saving Wikipedia kits for ${short}…`, true);
  setWikiKitButtons({ extractEnabled: false, saveEnabled: false });
  try {
    const data = await invokeFn(KITS_FN, {
      action: "sync_wikipedia_kits",
      wikipedia_url: lastWikiHit.url,
      wikipedia_title: lastWikiHit.title,
      club_short_name: short,
    });
    renderWikiKitPreviews(data, null);
    setStatus(
      "statusLine",
      data?.error
        ? data.error
        : `Saved wiki kits for ${short} → GitHub (${data?.github?.commit_sha || "ok"}).`,
      !data?.error
    );
  } catch (err) {
    setStatus("statusLine", err.message || String(err), false);
    setWikiKitButtons({
      extractEnabled: !!lastWikiHit,
      saveEnabled: !!lastWikiKits,
    });
  }
}

async function runLookup(event) {
  event?.preventDefault?.();
  const values = formValues();
  if (!values.clubName || !values.nationName) {
    setStatus("statusLine", "Club name and nation are required.", false);
    return;
  }

  const grid = document.getElementById("resultsGrid");
  if (grid) grid.hidden = false;

  setCardStatus("stadiumStatus", "Looking up…", "loading");
  setCardStatus("kitsStatus", "Looking up…", "loading");
  setCardStatus("wikiStatus", "Looking up…", "loading");
  document.getElementById("stadiumMeta").innerHTML = "";
  document.getElementById("kitsMeta").innerHTML = "";
  document.getElementById("wikiMeta").innerHTML = "";
  document.getElementById("stadiumPreview").innerHTML = "";
  document.getElementById("kitsPreview").innerHTML = "";
  document.getElementById("wikiList").innerHTML = "";
  document.getElementById("wikiKitsPreview") &&
    (document.getElementById("wikiKitsPreview").innerHTML = "");
  document.getElementById("wikiKitsMeta") &&
    (document.getElementById("wikiKitsMeta").innerHTML = "");
  lastWikiHit = null;
  lastWikiKits = null;
  setWikiKitButtons({ extractEnabled: false, saveEnabled: false });

  const btn = document.getElementById("lookupBtn");
  if (btn) btn.disabled = true;
  setStatus(
    "statusLine",
    `Looking up ${values.clubName} (${values.nationName})…`,
    true
  );

  const [stadiumSettled, kitsSettled, wikiSettled] = await Promise.allSettled([
    lookupStadium(values),
    lookupKits(values),
    lookupWikipedia(values),
  ]);

  renderStadium(
    stadiumSettled.status === "fulfilled" ? stadiumSettled.value : null,
    stadiumSettled.status === "rejected" ? stadiumSettled.reason : null
  );
  renderKits(
    kitsSettled.status === "fulfilled" ? kitsSettled.value : null,
    kitsSettled.status === "rejected" ? kitsSettled.reason : null
  );
  renderWiki(
    wikiSettled.status === "fulfilled" ? wikiSettled.value : null,
    wikiSettled.status === "rejected" ? wikiSettled.reason : null
  );

  if (btn) btn.disabled = false;

  const fails = [stadiumSettled, kitsSettled, wikiSettled].filter(
    (s) => s.status === "rejected"
  ).length;
  setStatus(
    "statusLine",
    fails
      ? `Lookup finished with ${fails} failed source(s).`
      : "Lookup finished.",
    fails === 0
  );
}

function renderCheckerRules() {
  renderRulesPanel(
    document.getElementById("clubCheckerRules"),
    {
      title: "Club checker",
      lead: `Enter a club (not necessarily in GPSL yet). Lookup runs <b>StadiumDB</b>, <b>Colours of Football</b>, and <b>Wikipedia</b> in parallel.`,
      notice: {
        title: "Edge functions required",
        body: `Redeploy <code>club-stadiums-sync</code> and <code>club-kits-cof-sync</code> (paste each <code>index.ts</code>, JWT OFF).
          Wikipedia <b>page link</b> works in-browser; <b>kit extraction</b> needs the updated kits edge function.`,
      },
      cards: [
        {
          heading: "StadiumDB",
          items: [
            "Uses stadium name + club name + nation (same matcher as stadium download).",
            "Shows StadiumDB page link and photo when found.",
          ],
        },
        {
          heading: "Kits (COF)",
          items: [
            "Matches club name on the nation index (folder short code, index often full name).",
            "Shows latest home / away / third kit images when available.",
          ],
        },
        {
          heading: "Wikipedia kits",
          items: [
            "Lookup finds the club page by <b>club name only</b>.",
            "Wikipedia kits are <b>layered templates</b> (not one PNG) — <b>Extract kits</b> composites home/away/third.",
            "Enter GPSL <b>ShortName</b> → <b>Save wiki kits → GitHub</b> writes <code>images/clubs_kits/{SHORT}_*.png</code>.",
          ],
        },
      ],
    },
    { rootClass: "info-box info-box--wide club-checker-rules" }
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  renderCheckerRules();
  document.getElementById("checkerForm")?.addEventListener("submit", runLookup);
  document.getElementById("wikiKitsBtn")?.addEventListener("click", () =>
    extractWikipediaKits()
  );
  document.getElementById("saveWikiKitsBtn")?.addEventListener("click", () =>
    saveWikipediaKits()
  );
  document.getElementById("clubShort")?.addEventListener("input", () => {
    const short = formValues().clubShort;
    setWikiKitButtons({
      extractEnabled: !!lastWikiHit,
      saveEnabled: !!(lastWikiKits && Object.keys(lastWikiKits).length && short),
    });
  });
  await initAdminPage();
});
