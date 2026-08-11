/**
 * Pending squad entries — players the club is winning on transfer market / draft,
 * or has a wage bid on for expiring contracts (hidden until season rollover).
 * Shown as ghost rows on squad.html (not contracted yet).
 */
import { getUKNow, loadGlobalSettings, isDraftAuctionEnded } from "./global.js";
import {
  isBuyerBidOnLiveAuction,
  isBuyerBidAwaitingSellerReview,
  getBidPlayerId,
} from "./direct_offers.js?v=20260811-ghost-lead";

const GHOST_PLAYER_COLUMNS =
  "Konami_ID, Name, Nation, Position, Rating, Potential, Calc_Potential, Age, market_value, Playstyle, Contracted_Team";

const GHOST_PLAYER_COLUMNS_LEGACY =
  "Konami_ID, Name, Nation, Position, Rating, Age, market_value, Playstyle, Contracted_Team";

export const GHOST_SOURCE = {
  TRANSFER_LIVE: "transfer_live",
  DRAFT_AUCTION: "draft_auction",
  AWAITING_SELLER: "awaiting_seller",
  EXPIRY_WAGE: "expiry_wage",
};

export const GHOST_SOURCE_LABELS = {
  [GHOST_SOURCE.TRANSFER_LIVE]: "Transfer market · winning bid",
  [GHOST_SOURCE.DRAFT_AUCTION]: "Draft auction · winning bid",
  [GHOST_SOURCE.AWAITING_SELLER]: "Transfer market · awaiting seller",
  [GHOST_SOURCE.EXPIRY_WAGE]: "Expiring contract · wage bid",
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
  if (source === GHOST_SOURCE.EXPIRY_WAGE) {
    return `expiring_contracts.html?player=${id}`;
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
    ghostIsWage: source === GHOST_SOURCE.EXPIRY_WAGE,
  };
}

/**
 * Merge any active expiring-contract wage bids for this club (winning or losing —
 * rivals' offers stay hidden until rollover).
 */
async function loadExpiryWagePending(supabase, pendingByPlayer) {
  const { data, error } = await supabase.rpc("list_expiring_contract_market");
  if (error) {
    console.warn("loadSquadGhostAcquisitions expiry market:", error);
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  for (const row of rows) {
    if (row?.my_wage_bid == null) continue;
    const pid = String(row.player_id || "").trim();
    if (!pid) continue;

    // Prefer an existing live transfer/draft ghost for the same player.
    if (pendingByPlayer.has(pid)) continue;

    pendingByPlayer.set(pid, {
      source: GHOST_SOURCE.EXPIRY_WAGE,
      bidAmount: Number(row.my_wage_bid),
    });
  }
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

  /** @type {Map<string, { source: string, bidAmount: number|null }>} */
  const pendingByPlayer = new Map();

  const { data: bidsRaw, error: bidsErr } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("bidder_club_id", clubShort)
    .eq("status", "active")
    .order("bid_time", { ascending: false });

  if (bidsErr) {
    console.warn("loadSquadGhostAcquisitions bids:", bidsErr);
  } else {
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
  }

  await loadExpiryWagePending(supabase, pendingByPlayer);

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
  if (source === GHOST_SOURCE.EXPIRY_WAGE) return "EXPIRY";
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
  const amount =
    ghost?.ghostBidAmount != null && Number.isFinite(ghost.ghostBidAmount)
      ? Number(ghost.ghostBidAmount).toLocaleString("en-GB")
      : null;
  const bid =
    amount != null
      ? ghost?.ghostIsWage || ghost?.ghostSource === GHOST_SOURCE.EXPIRY_WAGE
        ? `<span class="squad-ghost-bid">Wage ₿${amount}</span>`
        : `<span class="squad-ghost-bid">Bid ₿${amount}</span>`
      : "";
  return `<div class="squad-status-stack">
    <span class="status-pill status-ghost-pending">Pending</span>
    ${bid}
  </div>`;
}

export function ghostContractCellLabel(ghost) {
  if (ghost?.ghostSource === GHOST_SOURCE.EXPIRY_WAGE) {
    return "If successful";
  }
  return "If won";
}

export function ghostContractTip(ghost) {
  if (ghost?.ghostSource === GHOST_SOURCE.EXPIRY_WAGE) {
    return "Not contracted yet. Your wage bid stays hidden until season rollover — if you win, they join on a new 3-season contract. Ghost rows count toward “If won” registration previews only.";
  }
  return "Not contracted yet. If your winning bid settles, they join your squad on a new 3-season contract. Ghost rows count toward “If won” registration previews only.";
}

export function ghostActionLinkHtml(ghost) {
  const amount =
    ghost?.ghostBidAmount != null && Number.isFinite(ghost.ghostBidAmount)
      ? Number(ghost.ghostBidAmount).toLocaleString("en-GB")
      : null;
  const href = ghost?.ghostHref || "#";
  if (ghost?.ghostSource === GHOST_SOURCE.EXPIRY_WAGE) {
    return `<a href="${href}" class="squad-ghost-action-link">Wage bid${
      amount != null ? ` · ₿${amount}` : ""
    }</a>`;
  }
  return `<a href="${href}" class="squad-ghost-action-link">View bid${
    amount != null ? ` · ₿${amount}` : ""
  }</a>`;
}

export function ghostActionTip(ghost) {
  if (ghost?.ghostSource === GHOST_SOURCE.EXPIRY_WAGE) {
    return "Open Expiring Contracts — rival wage bids stay hidden until season rollover.";
  }
  return "Open the listing or draft auction where you are leading this bid.";
}
