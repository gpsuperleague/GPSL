/**
 * Shared transfer status labels for squad, club squad view, and GPDB.
 */

import {
  loadPendingDirectOfferState,
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

export function buildClubShortLookup(clubsRows) {
  const map = new Map();
  for (const c of clubsRows || []) {
    const short = String(c.ShortName || "").trim();
    const full = String(c.Club || "").trim();
    if (!short) continue;
    map.set(short, short);
    if (full) map.set(full, short);
  }
  return map;
}

export function normalizeClubShort(raw, state) {
  const t = String(raw || "").trim();
  if (!t) return "";
  return state?.clubShortByKey?.get(t) || t;
}

function rebuildPendingBySeller(bySeller, clubShortByKey) {
  const out = new Map();
  for (const [key, ids] of bySeller || []) {
    const norm = normalizeClubShort(key, { clubShortByKey });
    if (!norm) continue;
    if (!out.has(norm)) out.set(norm, new Set());
    for (const id of ids) out.get(norm).add(id);
  }
  return out;
}

function playerHasPendingOfferForSeller(state, konamiId, sellerRaw) {
  const pid = String(konamiId ?? "").trim();
  if (!pid || !state) return false;

  const sellerNorm = normalizeClubShort(sellerRaw, state);
  if (sellerNorm) {
    const pending = state.pendingDirectBySeller?.get(sellerNorm);
    if (pending?.has(pid)) return true;
  }

  for (const [key, ids] of state.pendingDirectBySeller || []) {
    if (normalizeClubShort(key, state) === sellerNorm && ids.has(pid)) {
      return true;
    }
  }

  return false;
}

export async function loadTransferStatusState(supabase) {
  const nowIso = new Date().toISOString();

  const [pendingState, clubsRes, activeRes, reviewRes] = await Promise.all([
    loadPendingDirectOfferState(supabase),
    supabase.from("Clubs").select("ShortName, Club"),
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

  const clubShortByKey = buildClubShortLookup(clubsRes.data);
  const pendingDirectBySeller = rebuildPendingBySeller(
    pendingState.bySeller,
    clubShortByKey
  );

  return {
    clubShortByKey,
    pendingDirectAll: pendingState.allPlayerIds,
    pendingDirectBySeller,
    activeListedPlayerIds,
    sellerReviewPlayerIds,
  };
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
  const sellerNorm = normalizeClubShort(contractedTeam, state);
  const viewerNorm = normalizeClubShort(viewerClubShort, state);
  const pageClubNorm = normalizeClubShort(pageClubShort || contractedTeam, state);
  const isViewerSeller =
    !!viewerNorm && !!sellerNorm && viewerNorm === sellerNorm;

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

  const hasPendingForSeller = playerHasPendingOfferForSeller(
    state,
    pid,
    sellerNorm || contractedTeam
  );

  if (hasPendingForSeller) {
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
    isViewerSeller &&
    playerHasPendingDirectOffer(state.pendingDirectAll, pid)
  ) {
    return {
      code: TRANSFER_STATUS.DIRECT_OFFER_SELLER,
      label: TRANSFER_STATUS_LABELS[TRANSFER_STATUS.DIRECT_OFFER_SELLER],
      pillClass: PILL_CLASS[TRANSFER_STATUS.DIRECT_OFFER_SELLER],
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
  const isMyClub =
    !!normalizeClubShort(viewerClubShort, state) &&
    normalizeClubShort(viewerClubShort, state) ===
      normalizeClubShort(sellerClub, state);

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
