/**
 * Stadium capacity expansion — quotes, orders, build status.
 */

import { supabase } from "./global.js";
import { formatMoney } from "./competition.js";
import { formatUkDateTime } from "./competition_calendar.js";

export async function syncStadiumExpansionProgress() {
  const { error } = await supabase.rpc("stadium_expansion_sync_progress", {
    p_club_short_name: null,
  });
  if (error) console.warn("stadium_expansion_sync_progress:", error);
}

export async function loadStadiumExpansionStatus() {
  await syncStadiumExpansionProgress();

  const { data, error } = await supabase
    .from("stadium_expansion_status_public")
    .select("*")
    .maybeSingle();

  if (error) {
    console.error("loadStadiumExpansionStatus:", error);
    return null;
  }
  return data;
}

export async function loadStadiumExpansionQuotes() {
  const { data, error } = await supabase
    .from("stadium_expansion_quotes_public")
    .select("*")
    .order("created_at", { ascending: false });

  if (error) {
    console.error("loadStadiumExpansionQuotes:", error);
    return [];
  }
  return data || [];
}

export async function createStadiumQuote(seats) {
  const { data, error } = await supabase.rpc("stadium_expansion_create_quote", {
    p_seats: seats,
  });

  if (error) {
    return { ok: false, msg: error.message || "Could not create quote." };
  }
  return { ok: true, quote: data };
}

export async function placeStadiumOrder(quoteId) {
  const { data, error } = await supabase.rpc("stadium_expansion_place_order", {
    p_quote_id: quoteId,
  });

  if (error) {
    return { ok: false, msg: error.message || "Could not place order." };
  }
  return { ok: true, orderId: data };
}

export async function cancelPreBuildOrder(orderId) {
  const { error } = await supabase.rpc("stadium_expansion_pre_build_cancel", {
    p_order_id: orderId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function day7StadiumDecision(orderId, continueBuild) {
  const { error } = await supabase.rpc("stadium_expansion_day7_decision", {
    p_order_id: orderId,
    p_continue: continueBuild,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function cancelBuildOrder(orderId) {
  const { error } = await supabase.rpc("stadium_expansion_cancel_build", {
    p_order_id: orderId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export function formatQuoteLabel(quote) {
  const seats = Number(quote.seats || 0).toLocaleString("en-GB");
  const cost = formatMoney(quote.total_cost);
  const cps = formatMoney(quote.cost_per_seat);
  const when = quote.created_at
    ? new Date(quote.created_at).toLocaleString("en-GB", {
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "";
  return `+${seats} seats · ${cost} (${cps}/seat) · ${when}`;
}

export function expansionBlockedReason(status) {
  if (!status) return null;
  const headroom = Number(status.headroom || 0);
  const max = Number(status.max_capacity || 0);
  const base = Number(status.base_capacity || 0);
  const current = Number(status.current_capacity || 0);

  if (max <= base && current >= max) {
    return "This stadium cannot be expanded (original size above expansion tiers).";
  }
  if (headroom <= 0 && !status.active_order_id) {
    return "Stadium is at maximum capacity — no further expansion available.";
  }
  return null;
}

export function renderBuildStatusHtml(status) {
  if (!status?.active_order_id) return "";

  const st = status.order_status;
  const seats = Number(status.seats_ordered || 0).toLocaleString("en-GB");
  const delivered = Number(status.seats_delivered || 0).toLocaleString("en-GB");

  if (st === "pre_build" || st === "awaiting_goahead") {
    const msg = status.pre_build_message || `${seats} seats ordered`;
    const day = status.pre_build_day || 1;
    let html = `
      <p class="build-status"><b>Pre-build day ${day}/7</b> — ${msg}</p>
    `;

    if (status.day7_decision_open) {
      const deadline = formatUkDateTime(status.day7_deadline_uk);
      html += `
        <p class="build-note">Before <b>${deadline} UK</b>: continue to build or cancel (Rapid Build Co cancellation fee applies).</p>
      `;
    }

    if (st === "pre_build" && day < 7) {
      html += `<p class="build-note">Cancel before day 7 for a full refund.</p>`;
    }

    return html;
  }

  if (st === "building") {
    const pct = status.build_progress_pct ?? 0;
    return `
      <p class="build-status"><b>Building</b> — ${delivered} / ${seats} seats delivered (${pct}%)</p>
      <p class="build-note">+25% of ordered seats each GPSL month (real-world week). Continues across pre-season if needed.</p>
    `;
  }

  return "";
}
