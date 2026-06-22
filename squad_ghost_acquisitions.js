/**
 * Pending squad entries — players the club is winning on transfer market or draft auction.
 * Shown as ghost rows on squad.html (not contracted yet).
 */
import { getUKNow, loadGlobalSettings, isDraftAuctionEnded } from "./global.js";
import {
  isBuyerBidOnLiveAuction,
  isBuyerBidAwaitingSellerReview,
  getBidPlayerId,
} from "./direct_offers.js";

const GHOST_PLAYER_COLUMNS =
  "Konami_ID, Name, Nation, Position, Rating, Potential, Calc_Potential, Age, market_value, Playstyle, Contracted_Team";

const GHOST_PLAYER_COLUMNS_LEGACY =
  "Konami_ID, Name, Nation, Position, Rating, Age, market_value, Playstyle, Contracted_Team";

export const GHOST_SOURCE = {
  TRANSFER_LIVE: "transfer_live",
  DRAFT_AUCTION: "draft_auction",
  AWAITING_SELLER: "awaiting_seller",
};

export const GHOST_SOURCE_LABELS = {
  [GHOST_SOURCE.TRANSFER_LIVE]: "Transfer market · winning bid",
  [GHOST_SOURCE.DRAFT_AUCTION]: "Draft auction · winning bid",
  [GHOST_SOURCE.AWAITING_SELLER]: "Transfer market · awaiting seller",
};

function isMissingEconomicsColumnError(error) {
  const msg = String(error?.message || "").toLowerCase();
  return msg.includes("potential") || msg.includes("calc_potential");
}

function ghostHref(source, konamiId) {
  const id = encodeURIComponent(String(konamiId));
  if (source === GHOST_SOURCE.DRAFT_AUCTION) {
    return `draftauction_player.html?player=${id}`;
  }
  return `GPDB.html?player=${id}`;
}

function ghostPlayerFromRow(player, meta) {
  const source = meta?.source || GHOST_SOURCE.TRANSFER_LIVE;
  return {
    ...player,
    ghost: true,
    ghostSource: source,
    ghostLabel: GHOST_SOURCE_LABELS[source] || "Pending signing",
    ghostHref: ghostHref(source, player.Konami_ID),
    ghostBidAmount: meta?.bidAmount != null ? Number(meta.bidAmount) : null,
  };
}

/**
 * @returns {Promise<object[]>} Player-shaped rows with ghost* fields (not on club contract).
 */
export async function loadSquadGhostAcquisitions(supabase, clubShort) {
  if (!supabase || !clubShort) return [];

  const clubKey = String(clubShort).trim().toUpperCase();
  const now = getUKNow();
  const settings = await loadGlobalSettings();
  const draftEnded = isDraftAuctionEnded(now, settings.draftStart);
  const filterOpts = { now, draftAuctionEnded: draftEnded };

  const { data: bidsRaw, error: bidsErr } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("bidder_club_id", clubShort)
    .eq("status", "active")
    .order("bid_time", { ascending: false });

  if (bidsErr) {
    console.warn("loadSquadGhostAcquisitions bids:", bidsErr);
    return [];
  }

  const listingIds = [
    ...new Set(
      (bidsRaw || [])
        .map((b) => b.listing_id)
        .filter((id) => id != null)
    ),
  ];

  const listingMap = new Map();
  if (listingIds.length) {
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .in("id", listingIds);
    listings?.forEach((l) => listingMap.set(l.id, l));
  }

  /** @type {Map<string, { source: string, bidAmount: number|null }>} */
  const pendingByPlayer = new Map();

  for (const row of bidsRaw || []) {
    const listing = listingMap.get(row.listing_id);
    const pid = getBidPlayerId(row);
    if (!pid) continue;

    let source = null;
    if (isBuyerBidOnLiveAuction(row, listing, clubShort, filterOpts)) {
      const isDraft =
        String(listing?.listing_type || "").toLowerCase() === "draft" ||
        row.is_first_draft_bid ||
        row.is_draft_join;
      source = isDraft ? GHOST_SOURCE.DRAFT_AUCTION : GHOST_SOURCE.TRANSFER_LIVE;
    } else if (
      isBuyerBidAwaitingSellerReview(row, listing, clubShort, filterOpts)
    ) {
      source = GHOST_SOURCE.AWAITING_SELLER;
    }

    if (!source) continue;

    const existing = pendingByPlayer.get(pid);
    if (!existing) {
      pendingByPlayer.set(pid, {
        source,
        bidAmount:
          row.bid_amount != null ? Number(row.bid_amount) : null,
      });
    }
  }

  if (!pendingByPlayer.size) return [];

  const numericIds = [
    ...new Set(
      [...pendingByPlayer.keys()]
        .map((id) => Number(id))
        .filter((n) => Number.isFinite(n))
    ),
  ];

  if (!numericIds.length) return [];

  let { data: players, error } = await supabase
    .from("Players")
    .select(GHOST_PLAYER_COLUMNS)
    .in("Konami_ID", numericIds);

  if (error && isMissingEconomicsColumnError(error)) {
    ({ data: players, error } = await supabase
      .from("Players")
      .select(GHOST_PLAYER_COLUMNS_LEGACY)
      .in("Konami_ID", numericIds));
  }

  if (error) {
    console.warn("loadSquadGhostAcquisitions players:", error);
    return [];
  }

  return (players || [])
    .filter((p) => {
      const team = String(p.Contracted_Team || "").trim().toUpperCase();
      return !team || team !== clubKey;
    })
    .map((p) => ghostPlayerFromRow(p, pendingByPlayer.get(String(p.Konami_ID))));
}

export function ghostAcquisitionTypeLabel(ghost) {
  const source = ghost?.ghostSource;
  if (source === GHOST_SOURCE.DRAFT_AUCTION) return "DRAFT";
  if (source === GHOST_SOURCE.AWAITING_SELLER) return "TRANSFER";
  if (source === GHOST_SOURCE.TRANSFER_LIVE) return "TRANSFER";
  return "PENDING";
}

export function formatGhostPlayerNameCell(ghost, qualBadgesHtml = "") {
  const name = escapeHtml(ghost?.Name || ghost?.Konami_ID || "—");
  const typeLabel = ghostAcquisitionTypeLabel(ghost);
  const href = ghost?.ghostHref || "#";
  return `
    <div class="squad-player-cell">
      <div class="squad-player-name-row">
        <a href="${href}" class="squad-ghost-player-link">${name}</a>${qualBadgesHtml}
      </div>
      <div class="squad-player-ghost-row">
        <span class="squad-ghost-type">${typeLabel}</span>
      </div>
    </div>`;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function formatGhostAcquisitionBadge(ghost) {
  const label = ghost?.ghostLabel || "Pending signing";
  return `<span class="squad-ghost-badge" title="Not contracted — shown for planning only">👻 ${label}</span>`;
}

export function formatGhostStatusHtml(ghost) {
  const bid =
    ghost?.ghostBidAmount != null && Number.isFinite(ghost.ghostBidAmount)
      ? `<span class="squad-ghost-bid">Bid ₿${Number(ghost.ghostBidAmount).toLocaleString("en-GB")}</span>`
      : "";
  return `<div class="squad-status-stack">
    <span class="status-pill status-ghost-pending">Pending</span>
    ${bid}
  </div>`;
}
