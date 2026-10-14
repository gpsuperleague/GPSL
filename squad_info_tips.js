/**
 * Squad page owner-help tip copy (hover / focus).
 */

import {
  contractEndWindow,
  isContractFinalHalf,
  isContractFinalYear,
  isPesdbLegacyCard,
} from "./player_contracts.js?v=20261014-window-icons";
import {
  isExpiryAuctionExempt,
  isOooOWageUpliftRenew,
} from "./squad_rules.js";
import { oooRenewUpliftPct } from "./wages.js";

export const SQUAD_TIPS = {
  card:
    "Player card image — click to open the eFootball card on pesdb.net (external card database).",

  name:
    "Player name — click to open this player’s GPSL career page (appearances, goals, transfer history, clubs).",

  nation:
    "Player’s nationality. Counts toward home-grown (HG) when it matches your club’s nation.",

  position:
    "Registered playing position from the card. Used for squad balance and match selection.",

  age:
    "Current age. Uncontested final-year renewal: home-grown ≤23, or non-home-grown ≤21. Older One of our Own skip the contested market and renew at +2.5% wage instead. Other players enter the contested expiry wage market.",

  rating:
    "Overall rating (and calculated potential in brackets when shown). Pot. is GPSL’s formula — not always the raw pesdb max level.\n\nRating also drives automatic star status (≥79 by default).",

  apps: "Appearances for your club this GPSL season (competition matches counted on this page).",

  goals: "Goals scored for your club this GPSL season.",

  assists: "Assists for your club this GPSL season.",

  avg: "Average match rating this GPSL season (when recorded).",

  playstyle:
    "Card playstyle (e.g. Goal Poacher, Anchor Man). Affects how the player plays in eFootball; shown here for squad planning.",

  marketValue:
    "GPSL market value (MV). Floor for transfer bids and foreign sales. Overflow releases and many settle payouts use MV (or a % of MV).",

  status:
    "Current availability — transfer-listed, injured, suspended, yellow-card tally, signing lock, etc.\n\nSigning lock: one full season after signing. Summer signings become sellable next summer; January signings from the next GPSL January (New Owner list can bypass that lock).",

  action:
    "Player actions: Transfer List, sell abroad (uses a foreign-interest slot), final-year renew / wage bid / legacy renew, medical consults, red-card appeals, set One of our own (HG star) or Fan Favourite (76–78, 50% wage — XOR, editable in GPSL preseason or January), and voluntary / New Owner releases when available.\n\nScroll sideways if the column is off-screen.",

  contractHeader:
    "Contract length + seasonal wage.\n\nEvery deal is 3 seasons from the window the player joined (summer → ends at the summer rollover; January → ends at GPSL January). Sale windows: locked for the first season after signing, sellable in the middle, locked again in the final half-season — when expiry wage bids open unless legacy or young HG / non-HG uncontested rules apply (hover a contract cell for that player’s path).",

  registration:
    "Squad registration for your club this season.\n\n• Size: at least 24 contracted players from August, never more than 28\n• ≥1 GK · ≥8 home-grown · ≥5 U21 (age ≤21)\n• Star cap (automatic by rating ≥79): Super League 3 / Championship 2 — One of our own (HG star you set) is excused from the cap\n• One of our own XOR Fan Favourite (76–78 any nation, Central Bank pays 50% wage). Nations with no GPDB 79+ get Fan Favourite only. Change in GPSL preseason or January only.\n\nFrom August, shortfalls and over-cap trigger ₿2.5m fines and emergency loans. Going over 28 on a signing: prefer a foreign-interest sell, else overflow release at MV + ₿10m fine.\n\nContract outlook (below): last-chance-to-sell warning before a player's final half-season locks; final-year split into re-signable vs contested wage market.",

  ifWon:
    "Projected count if your pending leading bids complete (transfer list, draft, or your expiry wage bid).\n\nGhost players are not contracted yet — if you are outbid, they drop off.",

  ghosts:
    "Pending acquisitions — players you are leading on (or have a locked expiry wage bid for) but do not own yet.\n\nShown for planning only. They count in the Registration “If won” column, including toward the star cap when eligible.",

  contractOutlook:
    "Season contract planning.\n\nLast chance to sell: players who can still be listed now but lock at the next switch — summer contracts in their final year lock at GPSL January; January contracts lock at the summer rollover before their final half.\n\nFinal-year block: re-signable on Squad (HG ≤23 / non-HG ≤21 / legacy) vs contested players on Expiring Contracts.",

  wageBillTitle:
    "Estimated seasonal wage bill for Close Finances — player contract wages plus manager salary (weekly × 52).",

  playerWages:
    "Sum of contracted player wages for the season. Posted when finances are closed for the GPSL month / season step.",

  managerSalary:
    "Your manager’s seasonal salary (weekly wage × 52). Included in the total wage bill on Finances.",

  totalWageBill:
    "Player wages + manager salary. Plan signings against this — wages hit the books at Close Finances.",

  manager:
    "Your club manager. Rating sets a season finish target for your division. Miss both seasons of a 2-season deal and they leave for market value (2-season rehire ban). Hit ≥1 target and you may renew in June/July — if not renewed before August starts, they are released for market value.\n\nList / Sack in June, July, and January (Jan needs the transfer window; also pre-season), and only from mid first spell (summer signing → January; January signing → next June–July). Sack costs half market value (once per season). List puts them on the Manager Transfer Market.\n\nNo manager? You cannot check in or play fixtures until one is signed.",

  managerArchived:
    "This manager is no longer in the live eFootball catalog. You may keep them until the deal ends. They cannot be listed on the transfer market or renewed — sack only. When the contract ends you receive full market value and they return to the archived database (history kept).",

  managerArchivedList:
    "Archived managers cannot be listed on the Manager Transfer Market. Keep them until the deal ends (full MV refund) or sack them.",

  managerDraftGhost:
    "Ghost manager — you currently hold the highest bid in the manager draft auction. They are not signed yet. If someone outbids you, this disappears. Click through to manage the auction.",

  managerList:
    "List your manager on the Manager Transfer Market. Needs the list/sack month window (June, July, January) and mid-spell tenure — summer signing: first chance in January; January signing: next June–July. Vacant clubs can still hire in August, but you cannot play without a manager.",

  managerSack:
    "Sack costs half market value (once per season). Needs the same month window and mid-spell tenure as List. Re-signing that manager is blocked until next season.",

  managerRenew:
    "Renew for another 2-season deal after hitting at least one finish target. Must be done before August starts or they are released for market value.",

  foreignInterest:
    "Foreign club sale slots left this season (max 3). Selling abroad at market value frees a squad place and can avoid overflow fines. Player is unavailable until next season. Use Sell to foreign club in Action.",

  voluntaryRelease:
    "Voluntary releases left this season (max 3). Buy-out = seasonal wage × seasons remaining (paid immediately, even if overdrawn). Player leaves as a free agent but cannot be signed by anyone until next season. Useful when you cannot sell.",

  newOwnerRelease:
    "First-season owner tools — up to 3 shared slots (release or transfer-list) in your first season at the club.\n\nWindow: pre-season through GPSL August, plus January when the transfer window is open.\n\nRelease refunds the recorded purchase fee. Transfer list at market value (slot returns if unsold). New Owner list can bypass the same-season lock.",

  starOoo:
    "Stars are automatic by rating (usually ≥79). Super League cap 3 / Championship 2. One of our own is a home-grown star you assign in Action — excused from the star cap. In their final year, if they would otherwise be contested (e.g. HG 24+), they stay off the expiry auction and you can renew at +2.5% wage (3 seasons); young OooO still renew at the same wage. Fan Favourite is a 76–78 (any nation) with 50% wage paid by Central Bank. You may set only one of OooO or Fan Favourite; editable in GPSL preseason or January. Nations with no GPDB 79+ get Fan Favourite only. Over-cap from August triggers fines and forced releases.",
};

export function squadContractTip(player, clubNation, oooPlayerId = null) {
  const n = Number(player?.contract_seasons_remaining);
  const wageNote =
    "The lower line is this player’s seasonal contract wage (counts toward your wage bill).";
  const janDeal = contractEndWindow(player) === "january";
  const endsAt = janDeal ? "GPSL January" : "the summer rollover";
  const finalHalf = isContractFinalHalf(player);
  const sellNote = finalHalf
    ? "Cannot Transfer List or sell — final half of the contract."
    : "Can still be listed or sold until GPSL January, when the final half locks.";

  if (isPesdbLegacyCard(player)) {
    if (isContractFinalYear(player)) {
      return (
        "Legacy card (no longer on pesdb.net) — final contract year.\n\n" +
        "Cannot be sold or listed. Not on the expiry wage auction. Use Action → Renew (1 season at a time). " +
        "If not renewed, they become a free agent at season rollover (club receives market value then).\n\n" +
        wageNote
      );
    }
    return (
      "Legacy card (removed from pesdb.net). Stays playable at your club but cannot be sold or listed until/unless a future sync restores the card.\n\n" +
      wageNote
    );
  }

  if (isContractFinalYear(player)) {
    if (isOooOWageUpliftRenew(player, clubNation, oooPlayerId)) {
      const uplift = oooRenewUpliftPct();
      return (
        `Final contract year — One of our Own (would otherwise be contested).\n\n` +
        `Protected from the expiry wage auction while they remain your One of our Own. ` +
        `Use Action to renew for 3 seasons at +${uplift}% wage. ` +
        `Each later final year works the same while they stay OooO. ` +
        `If you clear OooO, normal age/HG rules apply (often contested). ` +
        `${sellNote}\n\n` +
        wageNote
      );
    }
    if (isExpiryAuctionExempt(player, clubNation, oooPlayerId)) {
      return (
        "Final contract year — uncontested renewal (home-grown ≤23, or non-home-grown ≤21).\n\n" +
        "Protected from the expiry wage auction. Use Action to renew at the same wage (fresh 3-season deal). " +
        `If you do not renew, they become a free agent at ${endsAt} and your club receives market value then. ` +
        `${sellNote}\n\n` +
        wageNote
      );
    }
    if (player?.hasExpiryWageBid) {
      return (
        "Contract offered — pending expiry.\n\n" +
        "Your wage bid is locked for this player on the Expiring Contracts market. " +
        `Highest bid wins when the contract ends (${endsAt}). You cannot change the bid.\n\n` +
        wageNote
      );
    }
    if (!finalHalf) {
      return (
        "Final contract year — first half.\n\n" +
        "Last chance to sell: you can still Transfer List or sell abroad until GPSL January. " +
        "From GPSL January the final half locks sales and the Expiring Contracts wage bids open (other clubs and you may place one hidden bid; highest wins at the summer rollover).\n\n" +
        wageNote
      );
    }
    return (
      "Final half of the contract.\n\n" +
      `Cannot Transfer List or sell. They are on the Expiring Contracts market — other clubs (and you) may place one hidden wage bid; highest wins at ${endsAt}.\n\n` +
      "Use Action → Offer wage bid to compete. If nobody bids they become a free agent when the contract ends (holding club receives market value).\n\n" +
      wageNote
    );
  }

  if (Number.isFinite(n) && n === 2) {
    return (
      (janDeal
        ? "January contract — about 1½ seasons left.\n\n" +
          "Sellable until the summer rollover. After that the final half (to GPSL January) locks sales and wage bids open.\n\n"
        : "Two seasons remaining on this 3-season contract.\n\n" +
          "Next season is the final year: still sellable until GPSL January, then the final half locks sales and wage bids open.\n\n") +
      wageNote
    );
  }

  if (Number.isFinite(n) && n >= 3) {
    return (
      "Full (or reset) 3-season contract still running.\n\n" +
      "One-season signing lock after joining (summer signing → sellable next summer; January signing → next GPSL January), then you can list or sell (not legacy). Watch the countdown toward the final half.\n\n" +
      wageNote
    );
  }

  return SQUAD_TIPS.contractHeader;
}

export const SQUAD_COLUMN_TIPS = {
  "squad-col-thumb": SQUAD_TIPS.card,
  "squad-col-player": SQUAD_TIPS.name,
  "squad-col-nation": SQUAD_TIPS.nation,
  "squad-col-position": SQUAD_TIPS.position,
  "squad-col-age": SQUAD_TIPS.age,
  "squad-col-rating": SQUAD_TIPS.rating,
  "squad-col-playstyle": SQUAD_TIPS.playstyle,
  "squad-col-value": SQUAD_TIPS.marketValue,
  "squad-col-contract": SQUAD_TIPS.contractHeader,
  "squad-col-status": SQUAD_TIPS.status,
  "squad-col-action": SQUAD_TIPS.action,
};
