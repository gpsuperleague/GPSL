/**
 * Shared transfer status labels for squad, club squad view, and GPDB.
 */

import {
  loadPendingDirectOfferState,
  sellerPendingPlayerIds,
  playerHasPendingDirectOffer,
  playerHasActiveListing,
} from "./direct_offers.js";

export const TRANSFER_STATUS = {
  LISTED: "listed",
  SELLER_REVIEW: "seller_review",
  DIRECT_OFFER_SELLER: "direct_offer_seller",
  OFFER_PENDING: "offer_pending",
  NOT_LISTED: "not_listed",
  YOUR_PLAYER: "your_player",
  WINDOW_CLOSED: "window_closed",
  MAKE_OFFER: "make_offer",
};

/** Canonical user-facing copy (keep in sync across pages). */
export const TRANSFER_STATUS_LABELS = {
  [TRANSFER_STATUS.LISTED]: "Listed on market",
  [TRANSFER_STATUS.SELLER_REVIEW]: "Seller review",
  [TRANSFER_STATUS.DIRECT_OFFER_SELLER]:
    "Direct offer — review in Transfer Centre",
  [TRANSFER_STATUS.OFFER_PENDING]: "Offer pending",
  [TRANSFER_STATUS.NOT_LISTED]: "Not listed",
  [TRANSFER_STATUS.YOUR_PLAYER]: "Your Player",
  [TRANSFER_STATUS.WINDOW_CLOSED]: "Window Closed",
};

const PILL_CLASS = {
  [TRANSFER_STATUS.LISTED]: "status-listed",
  [TRANSFER_STATUS.SELLER_REVIEW]: "status-seller-review",
  [TRANSFER_STATUS.DIRECT_OFFER_SELLER]: "status-direct-offer",
  [TRANSFER_STATUS.OFFER_PENDING]: "status-offer-pending",
  [TRANSFER_STATUS.NOT_LISTED]: "status-not-listed",
};

export async function loadTransferStatusState(supabase) {
  const nowIso = new Date().toISOString();

  const [pendingState, activeRes, reviewRes] = await Promise.all([
    loadPendingDirectOfferState(supabase),
    supabase
      .from("Player_Transfer_Listings")
      .select("player_id, listing_type, status, end_time")
      .eq("status", "Active")
      .gt("end_time", nowIso),
    supabase
      .from("Player_Transfer_Listings")
      .select("player_id, listing_type, status")
      .in("status", ["Review", "Seller Review"]),
  ]);

  const activeListedPlayerIds = new Set();
  if (!activeRes.error) {
    for (const row of activeRes.data || []) {
      const lt = String(row.listing_type || "").toLowerCase();
      if (lt === "draft") continue;
      if (row.player_id == null) continue;
      activeListedPlayerIds.add(String(row.player_id).trim());
    }
  } else {
    console.error("loadTransferStatusState active listings:", activeRes.error);
  }

  const sellerReviewPlayerIds = new Set();
  if (!reviewRes.error) {
    for (const row of reviewRes.data || []) {
      const lt = String(row.listing_type || "").toLowerCase();
      if (lt === "draft") continue;
      if (row.player_id == null) continue;
      sellerReviewPlayerIds.add(String(row.player_id).trim());
    }
  } else {
    console.error("loadTransferStatusState seller review:", reviewRes.error);
  }

  return {
    pendingDirectAll: pendingState.allPlayerIds,
    pendingDirectBySeller: pendingState.bySeller,
    activeListedPlayerIds,
    sellerReviewPlayerIds,
  };
}

function pendingForSeller(state, sellerShort) {
  return sellerPendingPlayerIds(state, sellerShort);
}

/**
 * Core status for a contracted player.
 * @param {object} opts
 * @param {string} opts.konamiId
 * @param {string|null} opts.contractedTeam — seller short code
 * @param {string|null} opts.viewerClubShort — logged-in user's club
 * @param {object} opts.state — from loadTransferStatusState
 * @param {string|null} [opts.pageClubShort] — club.html squad owner (defaults to contractedTeam)
 */
export function resolvePlayerTransferStatus({
  konamiId,
  contractedTeam,
  viewerClubShort,
  state,
  pageClubShort = null,
}) {
  const pid = String(konamiId ?? "").trim();
  const sellerShort = String(contractedTeam || "").trim();
  const viewer = String(viewerClubShort || "").trim();
  const pageClub = String(pageClubShort || sellerShort || "").trim();
  const isViewerSeller = viewer && sellerShort && viewer === sellerShort;
  const isPageClubSquad = pageClub && sellerShort && pageClub === sellerShort;

  if (playerHasActiveListing(state.activeListedPlayerIds, pid)) {
    return {
      code: TRANSFER_STATUS.LISTED,
      label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.LISTED],
      pillClass: PILL_CLASS[TRANSFER_STATUS.LISTED],
    };
  }

  if (state.sellerReviewPlayerIds.has(pid)) {
    return {
      code: TRANSFER_STATUS.SELLER_REVIEW,
      label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.SELLER_REVIEW],
      pillClass: PILL_CLASS[TRANSFER_STATUS.SELLER_REVIEW],
    };
  }

  const sellerPending = pendingForSeller(state, sellerShort);
  if (sellerPending.has(pid)) {
    const label = isViewerSeller
      ? TRANSFER_STATUS_LABELS[TRANSFER_STATUS.DIRECT_OFFER_SELLER]
      : TRANSFER_STATUS_LABELS[TRANSFER_STATUS.OFFER_PENDING];
    return {
      code: isViewerSeller
        ? TRANSFER_STATUS.DIRECT_OFFER_SELLER
        : TRANSFER_STATUS.OFFER_PENDING,
      label,
      pillClass: isViewerSeller
        ? PILL_CLASS[TRANSFER_STATUS.DIRECT_OFFER_SELLER]
        : PILL_CLASS[TRANSFER_STATUS.OFFER_PENDING],
    };
  }

  if (
    !isViewerSeller &&
    playerHasPendingDirectOffer(state.pendingDirectAll, pid)
  ) {
    return {
      code: TRANSFER_STATUS.OFFER_PENDING,
      label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.OFFER_PENDING],
      pillClass: PILL_CLASS[TRANSFER_STATUS.OFFER_PENDING],
    };
  }

  return {
    code: TRANSFER_STATUS.NOT_LISTED,
    label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.NOT_LISTED],
    pillClass: PILL_CLASS[TRANSFER_STATUS.NOT_LISTED],
  };
}

/** Squad status column pill. */
export function formatSquadStatusHtml(status) {
  const pillClass = status.pillClass || PILL_CLASS[TRANSFER_STATUS.NOT_LISTED];
  return `<span class="status-pill ${pillClass}">${status.label}</span>`;
}

/** club.html / GPDB locked message span. */
export function formatTransferStatusMessageHtml(status, className = "locked-msg") {
  return `<span class="${className}">${status.label}</span>`;
}

/**
 * GPDB bid column for contracted players (draft/free agent handled separately).
 */
export function buildGpdbContractedBidCellHtml({
  player,
  viewerClubShort,
  state,
  transferWindowOpen,
}) {
  const konamiId = player.Konami_ID;
  const sellerClub = player.Contracted_Team;
  const isMyClub = viewerClubShort && sellerClub === viewerClubShort;

  const status = resolvePlayerTransferStatus({
    konamiId,
    contractedTeam: sellerClub,
    viewerClubShort,
    state,
  });

  if (status.code === TRANSFER_STATUS.LISTED) {
    return formatTransferStatusMessageHtml(status);
  }

  if (status.code === TRANSFER_STATUS.SELLER_REVIEW) {
    return formatTransferStatusMessageHtml(status);
  }

  if (status.code === TRANSFER_STATUS.DIRECT_OFFER_SELLER && isMyClub) {
    return formatTransferStatusMessageHtml(status);
  }

  if (status.code === TRANSFER_STATUS.OFFER_PENDING && !isMyClub) {
    return formatTransferStatusMessageHtml(status);
  }

  if (!isMyClub && transferWindowOpen) {
    return `<button class="button make-offer-btn" data-player-id="${konamiId}">Make Offer</button>`;
  }

  if (!transferWindowOpen) {
    return formatTransferStatusMessageHtml({
      code: TRANSFER_STATUS.WINDOW_CLOSED,
      label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.WINDOW_CLOSED],
    });
  }

  return formatTransferStatusMessageHtml({
    code: TRANSFER_STATUS.YOUR_PLAYER,
    label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.YOUR_PLAYER],
  });
}
