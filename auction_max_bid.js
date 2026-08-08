/**
 * Max-bid (proxy auto-bid) helpers for club / manager / player draft auctions.
 */
import { supabase } from "./supabase_client.js";
import { formatMoney } from "./competition.js";

export function parseMaxBidInput(raw) {
  const n = Number(String(raw ?? "").replace(/,/g, "").trim());
  return Number.isFinite(n) && n > 0 ? n : 0;
}

export async function clubAuctionGetMyMaxBid(clubShortName) {
  const { data, error } = await supabase.rpc("club_auction_get_my_max_bid", {
    p_club_short_name: clubShortName,
  });
  if (error) throw error;
  return data?.max_amount != null ? Number(data.max_amount) : null;
}

export async function clubAuctionSetMaxBid(clubShortName, maxAmount) {
  const { data, error } = await supabase.rpc("club_auction_set_max_bid", {
    p_club_short_name: clubShortName,
    p_max_amount: maxAmount,
  });
  if (error) throw error;
  return data;
}

export async function clubAuctionClearMaxBid(clubShortName) {
  const { data, error } = await supabase.rpc("club_auction_clear_max_bid", {
    p_club_short_name: clubShortName,
  });
  if (error) throw error;
  return data;
}

export async function managerDraftGetMyMaxBid(managerId) {
  const { data, error } = await supabase.rpc("manager_draft_get_my_max_bid", {
    p_manager_id: Number(managerId),
  });
  if (error) throw error;
  return data?.max_amount != null ? Number(data.max_amount) : null;
}

export async function managerDraftSetMaxBid(managerId, maxAmount) {
  const { data, error } = await supabase.rpc("manager_draft_set_max_bid", {
    p_manager_id: Number(managerId),
    p_max_amount: maxAmount,
  });
  if (error) throw error;
  return data;
}

export async function managerDraftClearMaxBid(managerId) {
  const { data, error } = await supabase.rpc("manager_draft_clear_max_bid", {
    p_manager_id: Number(managerId),
  });
  if (error) throw error;
  return data;
}

export async function playerDraftGetMyMaxBid(playerId) {
  const { data, error } = await supabase.rpc("player_draft_get_my_max_bid", {
    p_player_id: String(playerId),
  });
  if (error) throw error;
  return data?.max_amount != null ? Number(data.max_amount) : null;
}

export async function playerDraftSetMaxBid(playerId, maxAmount) {
  const { data, error } = await supabase.rpc("player_draft_set_max_bid", {
    p_player_id: String(playerId),
    p_max_amount: maxAmount,
  });
  if (error) throw error;
  return data;
}

export async function playerDraftClearMaxBid(playerId) {
  const { data, error } = await supabase.rpc("player_draft_clear_max_bid", {
    p_player_id: String(playerId),
  });
  if (error) throw error;
  return data;
}

export function maxBidStatusText(maxAmount) {
  if (maxAmount == null || !Number.isFinite(maxAmount) || maxAmount <= 0) {
    return "No max bid set — auto-bid off.";
  }
  return `Max bid ${formatMoney(maxAmount)} — auto-bids min step when outbid (never outbids yourself).`;
}
