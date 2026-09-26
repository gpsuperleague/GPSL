/**
 * GPDB — request a missing player by Konami ID
 * Lookup GPDB → if present, link to card; else PESDB preview → confirm → admin queue
 */
import { supabase } from "./supabase_client.js";
import {
  gpdbPlayerUrl,
  gpslPlayerCareerUrl,
  pesdbPlayerUrl,
  cachedPesdbPlayerCardUrl,
  PESDB_FALLBACK_CARD_IMG,
  escapePlayerHtml,
} from "./player_links.js";

const SCRAPE_FN = "gpdb-pesdb-scrape";

let busy = false;
let stagingPreview = null;

function $(id) {
  return document.getElementById(id);
}

function setStatus(msg, ok = true) {
  const el = $("gpdbAddPlayerStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.style.color = ok ? "#8d8" : "#f88";
}

function hideResult() {
  const wrap = $("gpdbAddPlayerResult");
  if (wrap) wrap.hidden = true;
  stagingPreview = null;
  const confirmBtn = $("gpdbAddPlayerConfirmBtn");
  if (confirmBtn) confirmBtn.hidden = true;
}

function showResult(html) {
  const wrap = $("gpdbAddPlayerResult");
  if (!wrap) return;
  wrap.innerHTML = html;
  wrap.hidden = false;
}

function previewCardHtml(row) {
  const kid = String(row.konami_id || "").trim();
  const name = escapePlayerHtml(row.player_name || row.name || "—");
  const img = cachedPesdbPlayerCardUrl(kid);
  const pos = escapePlayerHtml(row.position || "—");
  const nation = escapePlayerHtml(row.nationality || row.nation || "—");
  const age = escapePlayerHtml(String(row.age ?? "—"));
  const ovr = escapePlayerHtml(String(row.rating ?? row.max_level_rating ?? "—"));
  const style = escapePlayerHtml(row.playing_style || "—");
  const pesdb = pesdbPlayerUrl(kid);
  return `
    <div class="gpdb-add-player-card">
      <a href="${escapePlayerHtml(pesdb)}" target="_blank" rel="noopener">
        <img src="${escapePlayerHtml(img)}" alt="" width="72" height="100"
          onerror="this.onerror=null;this.src='${PESDB_FALLBACK_CARD_IMG}'">
      </a>
      <div>
        <div class="gpdb-add-player-name">${name}</div>
        <div class="gpdb-add-player-meta">${pos} · ${nation} · Age ${age} · OVR ${ovr}</div>
        <div class="gpdb-add-player-meta">${style} · Konami ${escapePlayerHtml(kid)}</div>
        <div class="gpdb-add-player-links">
          <a href="${escapePlayerHtml(pesdb)}" target="_blank" rel="noopener">PESDB</a>
        </div>
      </div>
    </div>`;
}

async function lookup() {
  if (busy) return;
  const input = $("gpdbAddPlayerKonamiId");
  const kid = String(input?.value || "").trim();
  hideResult();

  if (!/^\d+$/.test(kid)) {
    setStatus("Enter a numeric Konami ID.", false);
    return;
  }

  const { data: sessionData } = await supabase.auth.getSession();
  if (!sessionData?.session) {
    setStatus("Sign in to look up / request a player.", false);
    return;
  }

  busy = true;
  setStatus(`Checking GPDB for ${kid}…`);
  try {
    const { data: lookup, error: lookupErr } = await supabase.rpc(
      "gpdb_player_add_lookup",
      { p_konami_id: kid }
    );
    if (lookupErr) {
      const msg = lookupErr.message || "Lookup failed";
      if (/gpdb_player_add_lookup|Could not find/i.test(msg)) {
        throw new Error(
          "Run SQL patch gpdb_player_add_request_20260926.sql in Supabase first."
        );
      }
      throw new Error(msg);
    }

    if (lookup?.already_in) {
      const gpdb = lookup.gpdb_url || gpdbPlayerUrl(kid);
      const career = lookup.career_url || gpslPlayerCareerUrl(kid);
      showResult(`
        <p class="gpdb-add-player-banner ok">Already in GPDB</p>
        ${previewCardHtml({
          konami_id: kid,
          player_name: lookup.name,
          position: lookup.position,
          nationality: lookup.nation,
          age: lookup.age,
          rating: lookup.rating,
        })}
        <p class="gpdb-add-player-actions">
          <a class="button" href="${escapePlayerHtml(gpdb)}">Open in GPDB</a>
          <a class="button secondary" href="${escapePlayerHtml(career)}">GPSL player card</a>
        </p>`);
      setStatus(
        `${lookup.name} is already in GPDB (${lookup.contracted_team || "FA"}).`,
        true
      );
      return;
    }

    if (lookup?.pending) {
      showResult(`
        <p class="gpdb-add-player-banner">${escapePlayerHtml(lookup.message || "Pending admin review.")}</p>
        <p class="gpdb-add-player-meta">Konami ${escapePlayerHtml(kid)}${
          lookup.player_name
            ? ` · ${escapePlayerHtml(lookup.player_name)}`
            : ""
        }</p>`);
      setStatus(lookup.message || "Already requested.", true);
      return;
    }

    setStatus(`Looking up ${kid} on PESDB…`);
    const { data: scrape, error: scrapeErr } = await supabase.functions.invoke(
      SCRAPE_FN,
      {
        body: { action: "preview_one_player", konami_id: kid },
      }
    );
    if (scrapeErr) throw new Error(scrapeErr.message || "PESDB scrape failed");
    if (scrape?.ok === false && scrape?.error) throw new Error(scrape.error);

    const scraped = Array.isArray(scrape?.players) ? scrape.players[0] : null;
    if (!scraped) {
      throw new Error("No PESDB row returned — check the Konami ID.");
    }
    if (scraped.scrape_error) {
      throw new Error(`PESDB: ${scraped.scrape_error}`);
    }
    if (!scraped.player_name) {
      throw new Error("PESDB returned no player name for that ID.");
    }

    stagingPreview = {
      konami_id: kid,
      player_name: scraped.player_name,
      position: scraped.position || "CF",
      nationality: scraped.nationality || "",
      age: scraped.age ?? 25,
      rating: scraped.max_level_rating ?? scraped.rating ?? 60,
      max_level_rating: scraped.max_level_rating ?? scraped.rating ?? 60,
      playing_style: scraped.playing_style || "None",
      height_cm: scraped.height_cm,
      stronger_foot: scraped.stronger_foot,
      weak_foot_usage: scraped.weak_foot_usage,
      weak_foot_accuracy: scraped.weak_foot_accuracy,
      detail_url:
        scraped.detail_url ||
        `https://pesdb.net/efootball/?id=${kid}&mode=max_level`,
    };

    showResult(`
      <p class="gpdb-add-player-banner">Not in GPDB — confirm this is the right player</p>
      ${previewCardHtml(stagingPreview)}
      <p class="gpdb-add-player-hint">If correct, request admin to add them as a free agent.</p>
    `);
    const confirmBtn = $("gpdbAddPlayerConfirmBtn");
    if (confirmBtn) confirmBtn.hidden = false;
    setStatus(
      `PESDB: ${stagingPreview.player_name} · ${stagingPreview.position} · OVR ${stagingPreview.rating}`,
      true
    );
  } catch (err) {
    setStatus(err.message || "Lookup failed.", false);
  } finally {
    busy = false;
  }
}

async function confirmRequest() {
  if (busy || !stagingPreview) return;
  const row = stagingPreview;
  if (
    !confirm(
      `Request admin to add ${row.player_name} (${row.konami_id}) to GPDB?\n\n` +
        `${row.position} · OVR ${row.rating} · ${row.playing_style}`
    )
  ) {
    return;
  }

  busy = true;
  setStatus("Submitting request…");
  try {
    const { data, error } = await supabase.rpc("gpdb_player_add_submit", {
      p_konami_id: row.konami_id,
      p_preview: row,
    });
    if (error) throw new Error(error.message || "Submit failed");
    stagingPreview = null;
    const confirmBtn = $("gpdbAddPlayerConfirmBtn");
    if (confirmBtn) confirmBtn.hidden = true;
    showResult(`
      <p class="gpdb-add-player-banner ok">Request sent</p>
      <p>Admin will approve or reject <b>${escapePlayerHtml(
        data?.player_name || row.player_name
      )}</b> (Konami ${escapePlayerHtml(String(data?.konami_id || row.konami_id))}).</p>
    `);
    setStatus("Request queued for admin approval.", true);
    await refreshMyRequests();
  } catch (err) {
    setStatus(err.message || "Submit failed.", false);
  } finally {
    busy = false;
  }
}

async function refreshMyRequests() {
  const list = $("gpdbAddPlayerMyList");
  if (!list) return;
  try {
    const { data, error } = await supabase.rpc("gpdb_player_add_my_requests");
    if (error || !data?.ok) {
      list.innerHTML = "";
      return;
    }
    const rows = Array.isArray(data.rows) ? data.rows : [];
    if (!rows.length) {
      list.innerHTML = "";
      return;
    }
    list.innerHTML =
      `<div class="gpdb-add-player-my-title">Your recent requests</div>` +
      rows
        .slice(0, 8)
        .map((r) => {
          const st = String(r.status || "");
          const links =
            st === "approved"
              ? ` · <a href="${escapePlayerHtml(
                  r.gpdb_url || gpdbPlayerUrl(r.konami_id)
                )}">GPDB</a> · <a href="${escapePlayerHtml(
                  r.career_url || gpslPlayerCareerUrl(r.konami_id)
                )}">Card</a>`
              : "";
          const note =
            st === "rejected" && r.admin_note
              ? ` — ${escapePlayerHtml(r.admin_note)}`
              : "";
          return `<div class="gpdb-add-player-my-row"><span class="st ${escapePlayerHtml(
            st
          )}">${escapePlayerHtml(st)}</span> ${escapePlayerHtml(
            r.player_name || "—"
          )} (${escapePlayerHtml(r.konami_id)})${links}${note}</div>`;
        })
        .join("");
  } catch {
    list.innerHTML = "";
  }
}

export async function initGpdbAddPlayerRequest() {
  const panel = $("gpdbAddPlayerPanel");
  if (!panel) return;

  $("gpdbAddPlayerSearchBtn")?.addEventListener("click", lookup);
  $("gpdbAddPlayerConfirmBtn")?.addEventListener("click", confirmRequest);
  $("gpdbAddPlayerKonamiId")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      lookup();
    }
  });

  const { data: sessionData } = await supabase.auth.getSession();
  if (sessionData?.session) {
    await refreshMyRequests();
  }
}
