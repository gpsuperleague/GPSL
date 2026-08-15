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
  page:
    "Full player database. Filter, scout (☆), and bid: draft free agents when the window is open, or make a direct offer to contracted clubs. Watch same-season locks, final-year rules, and squad overflow (max 28).",
  draftCredits:
    "Draft auction join credits for this season. Listing a free agent on the draft spends a credit when the auction is created.",
  countdown:
    "Draft auction window timer. Bidding / listing free agents is only available while the draft phase is open.",
  filters:
    "Narrow by nation, position, age, rating, market value, wage, and more. Age/rating ±1 and market value ±₿500k via the stepper buttons when shown.",
  finalYear:
    "Show only players in their final contract year (1 season left). Contested ones appear on Expiring Contracts; young HG / non-HG renew on Squad.",
  myClubNation:
    "Filter to your club’s home nation — useful for home-grown planning (≥8 HG required).",
  scoutCol:
    "Add or remove this player from your scouting shortlist. Manage tiers and draft plans on the Scouting board.",
  bidCol:
    "Bid / offer depending on status: draft auction for free agents (when open), direct offer to contracted clubs, or locked messaging when unavailable.",
  callUpCol:
    "Call a player into your national squad (when you manage that nation). Separate from club contracts.",
  marketValue:
    "GPSL market value — usual floor for offers and draft bidding. Wage forecast for free agents uses a % of MV.",
  contractWage:
    "Seasonal contract wage when signed. Free agents show a forecast wage from market value for filter planning.",
  age: "Player age. Used for U21 registration (≥5) and uncontested expiry renewals (HG ≤23 / non-HG ≤21).",
  rating:
    "Overall rating. Also drives automatic star status (usually ≥79). Super League star cap 3 / Championship 2.",
  nation: "Nationality — matches your club nation for home-grown (HG) counts (≥8 required).",
  position: "Registered playing position from the card.",
  potential: "GPSL calculated potential (not always the raw pesdb max level).",
  contractedTeam:
    "Current club (or FREE AGENT). Contracted players need a direct offer; free agents use the draft when open.",
  seasonsRemaining:
    "Seasons left on the contract. Final year (1) cannot be listed/sold — contested players go to Expiring Contracts.",
  quickBid:
    "Raises your offer by one standard increment toward / above the minimum. Use ± buttons for fine control.",
  maxBid:
    "Optional auto max-bid on draft threads: when outbid, the system raises by ₿500k up to your ceiling (needs join credits).\n\nFair play: do not open or min-step probe auctions just to force rivals’ auto-bids up.",
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
  page:
    "Free-agent player draft. Bid while the auction window is open. Leading bids show as ghosts on Squad until settled — watch max 28, star cap, HG and U21.",
  credits:
    "Join credits let you list free agents into the draft auction. Winning bids settle when each listing ends — watch squad overflow and star cap on Squad.",
  status:
    "Draft phase / window status for this season (open, closed, or countdown). Bidding only works while the window is live.",
  timer:
    "Countdown to draft open or close (UK time). Add to calendar so you do not miss the window.",
  myBids:
    "Show only auctions where your club has placed a bid (leading or outbid).",
  showHidden:
    "Auctions you hid from this list (view only — your bids stay active). Tick to show them again and Unhide.",
  myClubLeading: "Show only auctions your club is currently leading.",
  scouted: "Show only players on your scouting shortlist (☆ from GPDB / Scouting board).",
  myNation: "Filter to your national team’s nation.",
  clubNation: "Filter to your club’s home nation (HG planning).",
  refresh:
    "How often the listing table reloads (1–300 seconds). Refresh now forces an immediate update.",
  age: "Filter by player age. Use − / + steppers for ±1 when shown.",
  rating: "Filter by overall rating. Use − / + for ±1 when shown.",
  currentBidRange:
    "Filter by highest bid amount. Money steps are ₿500,000 when using − / + steppers.",
  wage:
    "Filter by seasonal wage (signed wage, or forecast % of MV for free agents).",
  fav: "Star a thread to pin it under Saved draft auctions in Transfer Centre.",
  mv: "GPSL market value — usual reference for bidding. Minimum bid rules still apply on the player page.",
  highestBid:
    "Highest bid so far. Use Bid / Max bid on the player page. Auto max-bid raises for you up to your ceiling when rivals bid.\n\nFair play: do not min-step probe just to inflate prices against someone’s max bid.",
  leadingClub: "Club currently holding the high bid (empty if none yet).",
  owner: "Owner tag of the leading club (when known).",
  bidCol: "Open the player auction page to place or raise a bid (or view history).",
  hide:
    "Hide this auction from your list only (view). Bids stay live. Use Show hidden to restore.",
};

export const OWNER_DETAILS_TIPS = {
  page:
    "Your owner account: login, Discord tag, profile badge, weekly match availability, and holiday booking. Club kits and theme stay on Club Details.",
  availability:
    "Weekly free slots (30-minute blocks, UK time) used when proposing or responding to fixture times. Holidays overlay as unavailable — set your timezone for accurate proposals.",
  holiday:
    "Season allowance: 14 days total. Book real-world dates before the overlapping GPSL month opens so those fixtures unlock for arrange/play in the current GPSL week (both clubs need min 24 squad). Cancel/amend only while upcoming.",
  ownerTag:
    "Discord username shown publicly on fixtures and markets. Save locks it — use Edit to change later.",
  badge:
    "Your owner icon (not the club badge). Square image ideally 512×512, under 1 MB (PNG/JPEG/WebP), then Save badge.",
  email:
    "Confirmation link goes to the new email. Login only updates after you click that link.",
  password: "Minimum 6 characters. Requires your current password.",
};

export const BOARDROOM_TIPS = {
  page:
    "Board reviews finances, prestige expectations, manager deal, government subsidies, and league-position analysis. Missing expectation can hurt gate fill and may force a transfer listing.",
  finances:
    "Snapshot from club books. Advisory transfer budget is soft guidance and does not block bids. Full detail on Finances; loans at Central Bank.",
  financeRating:
    "Board cash confidence (A–E) from balance, projected end-of-season, wages, and loans. Hover for the numeric score.",
  expectations:
    "Prestige sets your baseline finish target. A strong manager can raise the bar on medium and low prestige clubs. Underperformance drifts gate fill down.",
  manager:
    "Managers sign 2-season deals. Hit ≥1 season target to renew; miss both → leave at market value with a 2-season rehire ban. List/sack in June, July, August, and January (Jan needs transfer window). Sack costs half MV once per season.",
  subsidies:
    "Status from your current squad. Payouts at season end when all divisions finish 38/38. HG bands: Quota ≤5, Flying 6–8, Pride 9+. Weak squad pays if enough ≤72-rated players.",
  analysis:
    "Last two seasons’ final league positions (1st at top). Full history on Club History.",
};

export const STADIUM_TIPS = {
  page:
    "Venue capacity, expansion orders, and estimated home gate. Actual receipts post to Club Finances after results are confirmed.",
  venue:
    "Current capacity vs club max / original base. Expansion is only available if you are at or below the new-build cap (typically ~55k).",
  expansion:
    "One expansion order per season. Cost per seat rises with current size. Payment posts immediately to Club Finances. Pre-build runs 7 days before building (+25% seats each GPSL month).",
  quote:
    "Get a quote for seats to add, then place the order to pay now. During pre-build you can cancel for a full refund before day 7.",
  gate:
    "Prestige sets base fill; on-target runs raise toward a full house; underperformance drifts fill down. League home: 100% to home; cup: 50/50 split.",
};

export const REWARDS_TIPS = {
  page:
    "Tokens and cards from challenge period bonuses (first club to finish all Start or Mid targets). Spend here, in Medical Room, Squad Action, or Special Auction.",
  inventory:
    "Your prize items and status (available, locked, or pending appeal). Empty until you win a period bonus.",
  discount:
    "Lock one fee discount to a transfer listing, draft listing, or special auction. Seller still gets the full fee; Central Bank tops up the gap. Only one discount locked at a time.",
  medical:
    "Doctor must be hired. One consult per injury (−2 / −4 / −6 / −8 / −10 matches). Same flow on Medical Room and Squad Action.",
  appeal:
    "Spend an appeal card on an active red-card ban. Admin reviews — DOGSO / clear goal-scoring chances are usually rejected.",
  draftToken:
    "Sign any uncontracted player at market value (paid to Central Bank). If squad is full (28), release someone first for MV credit.",
};

export const CHALLENGES_TIPS = {
  page:
    "Hit each target for cash when the result is confirmed. First club to finish every challenge in a window wins the big prize pack (auto to Rewards Centre + inbox).",
  bigPrize:
    "First to complete all Start or Mid challenges wins that pack (cash, medical tokens, fee discounts, appeal cards, draft tokens). Stays claimable until the latest deadline in that phase.",
  catalog:
    "Each card is a seasonal target (stat ≥ value in the GPSL month range) with a cash prize. Progress is tracked for your club.",
  standings:
    "Ranked by challenges completed, then overall progress. Your club is highlighted. Use Overall / Start / Mid tabs to filter.",
};

export const MATCHDAY_TIPS = {
  page:
    "Set your default matchday 23 (11 + 12) and submit results with optional squad stats. Opponent confirms via Inbox.",
  squad:
    "Default season matchday squad: 11 starters + 12 bench. Starters auto-tick Started on match stats. Formation presets only apply when you click Apply Default Formation.",
  submit:
    "Pick a scheduled or awaiting-confirm fixture. Enter score (cup may need ET / pens). Optional stats: exactly 11 Started, 0–5 Subbed on, goals must match your open-play total, one POTM.",
  yellow:
    "Yellow card. Player must have played. Eight yellows in a season = 2-match ban.",
  red: "Red card = 2-match ban. Player must have played. Appeals via Rewards Centre / Squad Action.",
  lineup:
    "Exactly 11 Started required. Subs optional (0–5 Subbed on). Suspended players cannot be selected.",
};

export const FIXTURES_TIPS = {
  page:
    "Your games are highlighted. Stadium/Continent = home venue (Wembley for cup finals). Propose time needs availability on Owner Details. Enter result opens Match Day for score + squad stats.",
  calendar:
    "Current GPSL play-month / calendar gate for arranging fixtures and submitting results.",
  propose:
    "Opens match scheduling. Home usually proposes first; respond before the deadline (misses can fine ₿2.5m each).",
};

export const MEDICAL_EXTRA_TIPS = {
  injuries:
    "Active injuries after doctor assessment. Refer to a specialist consultant (token) to shorten recovery — one consult per injury.",
};

export const SCOUTING_EXTRA_TIPS = {
  tacticBoard:
    "Drag scouting targets onto the pitch (11) and bench (17). Set Plan nation per board for HG / OooO when planning different clubs. Live GK / HG / U21 / ★ / MV update as you place players. Set a planned One of our Own to exclude them from the star count. Saved separately from Match Day.",
  targetsHeading:
    "Tiered shortlist from GPDB stars. Tick Active Targets to highlight spend and project registration (Sq / GK / HG / U21 / ★).",
};

export const TC_EXTRA_TIPS = {
  transfersIn:
    "Buying side: scouting, live high bids, deals waiting on sellers, and this season’s signings.",
  transfersOut:
    "Selling side: your live listings, closed listings, seller decisions, and this season’s sales.",
};
