/**
 * Shared owner-facing hover tip copy for non-admin pages.
 * Use with gpsl_info_tips.js (data-gpsl-tip / initGpslInfoTips).
 */

export const FINANCES_TIPS = {
  playerWages:
    "Sum of contracted player wages for the season. Posted when finances are closed (Close Finances / post season wage bills) — not weekly.",
  managerSalary:
    "Manager weekly wage × 52. Included in the seasonal wage bill charged at Close Finances.",
  totalWageBill:
    "Player wages + manager salary. Plan signings against this figure — it hits the books when finances are closed.",
  openingBalance:
    "GPSL starting budget for the season (before auctions), or last season’s archived closing balance carried forward.",
  currentBalance:
    "Spendable cash: opening balance plus all income and costs posted to the ledger so far. Click through for the full activity ledger.",
  predictedBalance:
    "Current balance plus pending forecasts from Season accounts (upcoming gates, wages, maintenance, unsettled winning bids, etc.).",
  advisoryBudget:
    "Soft spend guidance: current balance + predicted ops income − predicted ops costs (excluding transfer sales/purchases), minus live winning bids.\n\nShown as ₿0 minimum; does not block bids. Open Transfer Centre for context.",
  postedIncome: "Income lines already posted to this season’s ledger (gates, prizes, sales, subsidies, etc.).",
  postedCosts: "Cost lines already posted to this season’s ledger (purchases, wages, maintenance, fines, etc.).",
  postedNet: "Posted income minus posted costs this season. Open Season accounts for the workbook view.",
};

export const TRANSFER_CENTER_TIPS = {
  scouting:
    "Players you starred in GPDB (☆ column). Open the scouting board to plan draft bids and track active targets against registration rules.",
  draftFavourites:
    "Draft auction threads you starred on the Draft Auction page — quick jump back to those listings.",
  activeBids:
    "Open transfer-list auctions where you are currently the high bidder. Outbid rivals before the listing ends.",
  awaitingSeller:
    "Not on the open market anymore — ended below reserve, direct GPDB offers, or seller review. Below-reserve rows show an accept/reject cutoff with a countdown.",
  seasonSignings:
    "Players you signed this GPSL season. Same-season lock: you generally cannot list or sell them until next season.",
  activeListings:
    "Your players currently on the transfer list. Reserve price and live high bid appear here.",
  closedListings:
    "Finished listings (sold, expired, withdrawn). Clear hides them from this view only.",
  sellerReview:
    "Decisions waiting on you: accept/reject below-reserve bids before the cutoff, or respond to direct GPDB offers.",
  seasonSales: "Players you sold this GPSL season (fees already settled or recorded).",
};

export const GPDB_TIPS = {
  draftCredits:
    "Draft auction join credits for this season. Listing a free agent on the draft spends a credit when the auction is created.",
  finalYear:
    "Show only players in their final contract year (1 season left). Contested ones appear on Expiring Contracts; young HG / non-HG renew on Squad.",
  myClubNation:
    "Filter to your club’s home nation — useful for home-grown planning (≥8 HG required).",
  scoutCol:
    "Add or remove this player from your scouting shortlist. Manage tiers and draft plans on the Scouting board.",
  bidCol:
    "Bid / offer depending on status: draft auction for free agents (when open), direct offer to contracted clubs, or locked messaging when unavailable.",
  marketValue:
    "GPSL market value — usual floor for offers and draft bidding. Wage forecast for free agents uses a % of MV.",
  contractWage:
    "Seasonal contract wage when signed. Free agents show a forecast wage from market value for filter planning.",
};

export const EXPIRING_TIPS = {
  market:
    "Contested final-year players only. Place one hidden wage bid per player — locked once submitted. Highest wage wins a new 3-season deal at season rollover; ties favour the holding club.",
  yourBid:
    "Your locked wage offer for this player (hidden from rivals until rollover). Cannot be changed after submit.",
  currentWage: "Player’s current seasonal contract wage. Bids must clear the minimum uplift above this.",
  league:
    "Holding club’s division. Championship clubs taking a Super League player also pay a signing-on fee % of MV to the player at rollover.",
  mv: "Market value paid to the holding club if another club wins the wage auction at season rollover.",
};

export const DRAFT_TIPS = {
  credits:
    "Join credits let you list free agents into the draft auction. Winning bids settle when the auction ends — watch squad overflow and star cap.",
  currentBid:
    "Highest bid so far. Use Bid / Max bid on the player page. Auto max-bid raises for you up to your ceiling when rivals bid.",
  status:
    "Listing state — active bidding, ended, or settled. Favourites pin threads for Transfer Centre.",
};
