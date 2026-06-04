/**
 * Season transfer totals from Transfer_History (source of truth when ledger lines are missing).
 */

import { normalizeClubKey } from "./competition.js";
import { isForeignBuyerClub, resolveClubShortName } from "./clubs_lookup.js";

const TRANSFER_HISTORY_SELECT =
  "player_id, seller_club_id, buyer_club_id, fee, agent_fee, transfer_time, listing_id, foreign_buyer_name, transfer_sale_note";

export async function loadCurrentSeasonStart(supabase) {
  const { data, error } = await supabase
    .from("competition_season_public")
    .select("started_at")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("loadCurrentSeasonStart:", error);
    return null;
  }
  return data?.started_at || null;
}

/** @param {import("@supabase/supabase-js").SupabaseClient} supabase */
export async function loadClubTransferHistoryForSeason(supabase, seasonStartedAt) {
  let q = supabase
    .from("Transfer_History")
    .select(TRANSFER_HISTORY_SELECT)
    .order("transfer_time", { ascending: false });

  if (seasonStartedAt) {
    q = q.gte("transfer_time", seasonStartedAt);
  }

  const { data, error } = await q.limit(800);
  if (error) {
    console.error("loadClubTransferHistoryForSeason:", error);
    return [];
  }
  return data || [];
}

/**
 * @param {Array<Record<string, unknown>>} rows — full league history for the season
 * @param {string} clubShortName
 */
export function aggregateClubTransfersFromHistory(rows, clubShortName) {
  const me = normalizeClubKey(clubShortName);
  let sales = 0;
  let purchases = 0;
  /** @type {Record<string, number>} */
  const salesDetail = {};
  /** @type {Record<string, number>} */
  const purchasesDetail = {};

  for (const r of rows) {
    const seller = normalizeClubKey(resolveClubShortName(r.seller_club_id));
    const buyer = normalizeClubKey(resolveClubShortName(r.buyer_club_id));
    const fee = Number(r.fee) || 0;
    const agent = Number(r.agent_fee) || 0;
    const note = String(r.transfer_sale_note || "").trim();

    if (seller === me && fee > 0) {
      let type = "transfer_sale";
      if (note === "squad_overflow") {
        type = isForeignBuyerClub(r.buyer_club_id)
          ? "transfer_foreign_sale"
          : "transfer_overflow_release";
      } else if (isForeignBuyerClub(r.buyer_club_id)) {
        type = "transfer_foreign_sale";
      }
      sales += fee;
      salesDetail[type] = (salesDetail[type] || 0) + fee;
    }

    if (buyer === me && !isForeignBuyerClub(r.buyer_club_id)) {
      if (fee > 0) {
        purchases -= fee;
        purchasesDetail.transfer_purchase =
          (purchasesDetail.transfer_purchase || 0) - fee;
      }
      if (agent > 0) {
        purchases -= agent;
        purchasesDetail.transfer_agent_fee =
          (purchasesDetail.transfer_agent_fee || 0) - agent;
      }
    }
  }

  return {
    sales,
    purchases,
    net: sales + purchases,
    salesDetail,
    purchasesDetail,
    dealCount: rows.filter((r) => {
      const seller = normalizeClubKey(resolveClubShortName(r.seller_club_id));
      const buyer = normalizeClubKey(resolveClubShortName(r.buyer_club_id));
      return seller === me || buyer === me;
    }).length,
  };
}

/**
 * Ledger transfer net not yet reflected in competition_finance_ledger.
 * @param {{ sales: number, purchases: number }} agg
 * @param {Map<string, { amount: number }>} byLine — before merge
 */
export function transferHistoryBalanceGap(agg, byLine) {
  const ledgerSales = Number(byLine.get("transfer_sales")?.amount || 0);
  const ledgerPurch = Number(byLine.get("transfer_purchases")?.amount || 0);
  const historyNet = agg.sales + agg.purchases;
  const ledgerNet = ledgerSales + ledgerPurch;
  return historyNet - ledgerNet;
}

/**
 * @param {Map<string, { amount: number, detail?: Record<string, number>, fromHistory?: boolean }>} byLine
 * @param {ReturnType<typeof aggregateClubTransfersFromHistory>} agg
 */
export function mergeTransferHistoryIntoByLine(byLine, agg) {
  const applyLine = (id, amount, detail) => {
    if (Math.abs(amount) < 0.001) return;
    const existing = byLine.get(id);
    const ledgerAmt = Number(existing?.amount || 0);
    if (Math.abs(amount) <= Math.abs(ledgerAmt) + 0.001) return;

    byLine.set(id, {
      amount,
      detail: { ...detail },
      fromHistory: true,
    });
  };

  applyLine("transfer_sales", agg.sales, agg.salesDetail);
  applyLine("transfer_purchases", agg.purchases, agg.purchasesDetail);
}
