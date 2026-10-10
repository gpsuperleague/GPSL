/**
 * Stadium → Commercial panel: main sponsor (offers / current deal),
 * pitchside advertising boards, and merchandising.
 */
import { formatMoney } from "./competition.js";
import { brandLogoHtml, isKofiBrand, KOFI_URL } from "./brand_logos.js?v=20261008-local";

const TIER_LABELS = { big: "Big club", medium: "Medium club", low: "Small club" };

const PERF_TITLE_MIN_POINTS = 88;

const DEAL_TITLES = {
  long: "Long-term deal",
  short: "One-season deal",
  performance: "Performance deal",
};

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function money(n) {
  return formatMoney(Number(n) || 0);
}

function offerTerms(o) {
  if (o.deal_kind === "long") {
    return `<b>${money(o.amount_per_season)}</b> a season for <b>${o.seasons} seasons</b> (${money(
      o.amount_per_season * o.seasons
    )} total). <b>Guaranteed</b>, whatever happens on the pitch.`;
  }
  if (o.deal_kind === "short") {
    if (o.base_amount == null) {
      return `<b>${money(o.amount_per_season)}</b> for <b>this season only</b>.`;
    }
    return `<b>${money(o.base_amount)}</b> now, plus <b>${money(
      o.max_amount - o.base_amount
    )}</b> at Close Finances (${money(o.max_amount)} total) if you're on target, only slightly miss, or reach a cup target. Miss by 3+ places and you keep just the ${money(
      o.base_amount
    )}. This season only.`;
  }
  return `<b>${money(o.base_amount)}</b> now. Finish <b>above your expected league position</b> (expected to win the league? <b>win it with ${PERF_TITLE_MIN_POINTS}+ points</b>) and get another <b>${money(
    o.max_amount - o.base_amount
  )}</b> at Close Finances (${money(o.max_amount)} total). Otherwise nothing more. This season only.`;
}

function sponsorTerms(sp) {
  if (sp.deal_kind === "performance" || (sp.deal_kind === "short" && sp.base_amount != null)) {
    const title = sp.deal_kind === "performance" ? "Performance deal" : "One-season deal";
    const rule =
      sp.deal_kind === "performance"
        ? `if you finish above your expected league position (or, if expected to win the league, win it with ${PERF_TITLE_MIN_POINTS}+ points)`
        : "if you're on target, only slightly miss, or reach a cup target";
    return sp.bonus_paid
      ? `${title} — ${money(sp.paid_this_season)} received this season in total.`
      : `${title} — ${money(sp.base_amount)} paid; another ${money(
          sp.max_amount - sp.base_amount
        )} at Close Finances ${rule}.`;
  }
  const seasonNote =
    sp.seasons_total > 1 ? ` · season ${sp.season_number} of ${sp.seasons_total}` : " · this season only";
  return `${DEAL_TITLES[sp.deal_kind] || "Deal"} — ${money(sp.amount_per_season)} per season${seasonNote}.`;
}

function renderSponsor(d) {
  if (d.sponsor) {
    const sp = d.sponsor;
    return `
      <div class="comm-sponsor">
        ${brandLogoHtml(sp.brand, "brand-logo--lg")}
        <div class="comm-sponsor-body">
          <div class="comm-kicker">Main sponsor</div>
          <div class="comm-sponsor-name">${esc(sp.brand)}</div>
          <div class="comm-sector">${esc(sp.sector)}${sp.tagline ? ` — “${esc(sp.tagline)}”` : ""}</div>
          <p class="comm-terms">${sponsorTerms(sp)}</p>
          ${sp.auto_selected ? `<p class="note">Signed automatically when the offer deadline passed.</p>` : ""}
        </div>
      </div>`;
  }

  const offers = Array.isArray(d.offers) ? d.offers : [];
  if (!offers.length) {
    return `<p class="empty">No sponsorship offers yet. Three offers arrive in your inbox when GPSL June starts — or soon after you take over a club, if it's past June.</p>`;
  }

  const deadline = offers[0]?.expires_at
    ? new Date(offers[0].expires_at).toLocaleString("en-GB", {
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "";

  const cards = offers
    .map(
      (o) => `
      <div class="comm-offer">
        <div class="comm-kicker">${esc(DEAL_TITLES[o.deal_kind] || o.deal_kind)}</div>
        <div class="comm-offer-head">
          ${brandLogoHtml(o.brand, "brand-logo--md")}
          <div class="comm-offer-brand">${esc(o.brand)}</div>
        </div>
        <div class="comm-sector">${esc(o.sector)}${o.tagline ? ` — “${esc(o.tagline)}”` : ""}</div>
        <p class="comm-terms">${offerTerms(o)}</p>
        ${
          d.can_decide
            ? `<button type="button" class="btn-result comm-accept" data-offer-id="${o.id}" data-brand="${esc(
                o.brand
              )}">Sign with ${esc(o.brand)}</button>`
            : ""
        }
      </div>`
    )
    .join("");

  return `
    <p class="comm-dilemma"><b>Three companies want their name on your stadium.</b> Guaranteed money, a deal that depends on avoiding a big miss, or a big-bonus gamble on beating expectations?
      ${deadline ? `Decide by <b>${esc(deadline)}</b> — otherwise the long-term deal is signed for you.` : ""}</p>
    <div class="comm-offers">${cards}</div>`;
}

function renderBoards(d) {
  const boards = Array.isArray(d.boards) ? d.boards : [];
  if (!boards.length) {
    return `<p class="empty">Pitchside boards are sold when GPSL June starts.</p>`;
  }
  const total = boards.reduce((s, b) => s + (Number(b.amount) || 0), 0);
  const chips = boards
    .map((b) => {
      const inner = `
        ${brandLogoHtml(b.brand, "brand-logo--board")}
        <span class="comm-board-name">${esc(b.brand)}</span>
        <span class="comm-board-sector">${esc(b.sector)}</span>
        <span class="comm-board-amt">${money(b.amount)}</span>`;
      return isKofiBrand(b.brand)
        ? `<a class="comm-board comm-board--kofi" href="${KOFI_URL}" target="_blank" rel="noopener noreferrer" title="Support GPSL on Ko-fi">${inner}</a>`
        : `<div class="comm-board" title="${esc(b.tagline || "")}">${inner}</div>`;
    })
    .join("");
  return `<div class="comm-boards">${chips}</div>
    <p class="note">Total pitchside advertising this season: <b>${money(total)}</b> (priced on last season's results).</p>`;
}

function renderMerch(d) {
  if (d.merch) {
    return `<dl class="breakdown">
      <dt>Club shop (kits &amp; novelties)</dt><dd>${money(d.merch.shop)}</dd>
      <dt>Global kit sales</dt><dd>${money(d.merch.global)}</dd>
      <dt>Total</dt><dd class="highlight">${money(d.merch.total)}</dd>
    </dl>`;
  }
  return `<p class="empty">Paid at Close Finances: club shop (kits &amp; novelties) plus global kit sales —
    between ${money(d.band_min)} and ${money(d.band_max)} depending on league &amp; cup results vs targets and how full your stadium is.</p>`;
}

async function loadAndRender(supabase, clubShort, root) {
  const { data, error } = await supabase.rpc("club_commercial_get_club", {
    p_club_short_name: clubShort,
  });

  if (error) {
    const missing = /could not find|does not exist|schema cache/i.test(error.message || "");
    root.innerHTML = missing
      ? `<p class="empty">Commercial income isn't switched on yet.</p>`
      : `<p class="expansion-hint expansion-hint--error">${esc(error.message)}</p>`;
    return;
  }

  const d = data || {};
  if (!d.enabled) {
    root.innerHTML = `<p class="empty">Commercial income is currently switched off.</p>`;
    return;
  }

  const tier = TIER_LABELS[d.tier] || "Club";
  root.innerHTML = `
    <p class="meta">${esc(tier)} — each stream pays ${money(d.band_min)}–${money(d.band_max)} a season, scaled by league &amp; cup results against targets. Paid by the Central Bank.</p>
    <h3 class="comm-h3">Main sponsor</h3>
    ${renderSponsor(d)}
    <h3 class="comm-h3">Pitchside advertising</h3>
    ${renderBoards(d)}
    <h3 class="comm-h3">Merchandising</h3>
    ${renderMerch(d)}
    <p id="commercialStatus" class="expansion-hint" role="status"></p>`;

  root.querySelectorAll(".comm-accept").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const brand = btn.dataset.brand || "this sponsor";
      if (!confirm(`Sign ${brand} as your main sponsor? The other two offers will be declined.`)) return;
      root.querySelectorAll(".comm-accept").forEach((b) => (b.disabled = true));
      const status = root.querySelector("#commercialStatus");
      const { error: accErr } = await supabase.rpc("club_commercial_accept_offer", {
        p_offer_id: Number(btn.dataset.offerId),
      });
      if (accErr) {
        if (status) {
          status.textContent = accErr.message || "Could not sign the deal.";
          status.classList.add("expansion-hint--error");
        }
        root.querySelectorAll(".comm-accept").forEach((b) => (b.disabled = false));
        return;
      }
      await loadAndRender(supabase, clubShort, root);
    });
  });
}

export async function mountStadiumCommercial(supabase, clubShort) {
  const root = document.getElementById("commercialContent");
  if (!root || !clubShort) return;
  root.innerHTML = `<p class="empty">Loading…</p>`;
  try {
    await loadAndRender(supabase, clubShort, root);
  } catch (e) {
    root.innerHTML = `<p class="expansion-hint expansion-hint--error">${esc(e?.message || e)}</p>`;
  }
}
