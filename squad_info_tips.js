/**
 * Squad page owner-help tip copy (hover / focus).
 */

import { isContractFinalYear, isPesdbLegacyCard } from "./player_contracts.js";
import { isExpiryAuctionExempt } from "./squad_rules.js";

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
    "Current age. Uncontested final-year renewal: home-grown ≤23, or non-home-grown ≤21. Once they age out of that band they enter the contested expiry wage market.",

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
    "Current availability — transfer-listed, injured, suspended, yellow-card tally, same-season lock, etc.\n\nSigned this season? Cannot Transfer List or sell until next season (New Owner list can bypass that lock).",

  action:
    "Player actions: Transfer List, sell abroad (uses a foreign-interest slot), final-year renew / wage bid / legacy renew, medical consults, red-card appeals, set One of our own (HG star) or Fan Favourite (76–78, 50% wage — XOR, editable in GPSL preseason or January), and voluntary / New Owner releases when available.\n\nScroll sideways if the column is off-screen.",

  contractHeader:
    "Contract length + seasonal wage.\n\nStandard deals are 3 seasons. In the final year the player cannot be listed or sold — they enter the expiry wage auction unless legacy or young HG / non-HG uncontested rules apply (hover a contract cell for that player’s path).",

  registration:
    "Squad registration for your club this season.\n\n• Size: at least 24 contracted players from August, never more than 28\n• ≥1 GK · ≥8 home-grown · ≥5 U21 (age ≤21)\n• Star cap (automatic by rating ≥79): Super League 3 / Championship 2 — One of our own (HG star you set) is excused from the cap\n• One of our own XOR Fan Favourite (76–78 any nation, Central Bank pays 50% wage). Nations with no GPDB 79+ get Fan Favourite only. Change in GPSL preseason or January only.\n\nFrom August, shortfalls and over-cap trigger ₿2.5m fines and emergency loans. Going over 28 on a signing: prefer a foreign-interest sell, else overflow release at MV + ₿10m fine.\n\nContract outlook (below): December/January heads-up for 2-season deals; final-year split into re-signable vs contested wage market.",

  ifWon:
    "Projected count if your pending leading bids complete (transfer list, draft, or your expiry wage bid).\n\nGhost players are not contracted yet — if you are outbid, they drop off.",

  ghosts:
    "Pending acquisitions — players you are leading on (or have a locked expiry wage bid for) but do not own yet.\n\nShown for planning only. They count in the Registration “If won” column, including toward the star cap when eligible.",

  contractOutlook:
    "Season contract planning.\n\nIn December/January, players with 2 seasons left get a January-window sell warning (next season they enter final year and cannot be sold).\n\nFinal-year block: re-signable on Squad (HG ≤23 / non-HG ≤21 / legacy) vs contested players on Expiring Contracts.",

  wageBillTitle:
    "Estimated seasonal wage bill for Close Finances — player contract wages plus manager salary (weekly × 52).",

  playerWages:
    "Sum of contracted player wages for the season. Posted when finances are closed for the GPSL month / season step.",

  managerSalary:
    "Your manager’s seasonal salary (weekly wage × 52). Included in the total wage bill on Finances.",

  totalWageBill:
    "Player wages + manager salary. Plan signings against this — wages hit the books at Close Finances.",

  manager:
    "Your club manager. Rating sets a season finish target for your division. Miss both seasons of a 2-season deal and they leave for market value (2-season rehire ban). Hit ≥1 target and you may renew in June/July — if not renewed before August starts, they are released for market value.\n\nList / Sack in June, July, August, and January (January needs the transfer window open; also available in pre-season). Sack costs half market value (once per season) and needs mid-spell tenure. List puts them on the Manager Transfer Market.\n\nNo manager? You cannot check in or play fixtures until one is signed.",

  managerDraftGhost:
    "Ghost manager — you currently hold the highest bid in the manager draft auction. They are not signed yet. If someone outbids you, this disappears. Click through to manage the auction.",

  managerList:
    "List your manager on the Manager Transfer Market. Available in June, July, August, and January (Jan needs transfer window). Vacant clubs can still hire in August, but you cannot play without a manager.",

  managerSack:
    "Sack costs half market value (once per season) and needs mid-spell tenure. Re-signing that manager is blocked until next season. Same month window as List.",

  managerRenew:
    "Renew for another 2-season deal after hitting at least one finish target. Must be done before August starts or they are released for market value.",

  foreignInterest:
    "Foreign club sale slots left this season (max 3). Selling abroad at market value frees a squad place and can avoid overflow fines. Player is unavailable until next season. Use Sell to foreign club in Action.",

  voluntaryRelease:
    "Voluntary releases left this season (max 3). Buy-out = seasonal wage × seasons remaining (paid immediately, even if overdrawn). Player leaves as a free agent but cannot be signed by anyone until next season. Useful when you cannot sell.",

  newOwnerRelease:
    "First-season owner tools — up to 3 shared slots (release or transfer-list) in your first season at the club.\n\nWindow: pre-season through GPSL August, plus January when the transfer window is open.\n\nRelease refunds the recorded purchase fee. Transfer list at market value (slot returns if unsold). New Owner list can bypass the same-season lock.",

  starOoo:
    "Stars are automatic by rating (usually ≥79). Super League cap 3 / Championship 2. One of our own is a home-grown star you assign in Action — excused from the star cap. Fan Favourite is a 76–78 (any nation) with 50% wage paid by Central Bank. You may set only one of OooO or Fan Favourite; editable in GPSL preseason or January. Nations with no GPDB 79+ get Fan Favourite only. Over-cap from August triggers fines and forced releases.",
};

export function squadContractTip(player, clubNation) {
  const n = Number(player?.contract_seasons_remaining);
  const wageNote =
    "The lower line is this player’s seasonal contract wage (counts toward your wage bill).";

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
    if (isExpiryAuctionExempt(player, clubNation)) {
      return (
        "Final contract year — uncontested renewal (home-grown ≤23, or non-home-grown ≤21).\n\n" +
        "Protected from the expiry wage auction. Use Action to renew at the same wage (fresh 3-season deal). " +
        "Cannot expire mid-season — if you do not renew, they become a free agent at season rollover and your club receives market value then. " +
        "Cannot Transfer List or sell while in the final year.\n\n" +
        wageNote
      );
    }
    if (player?.hasExpiryWageBid) {
      return (
        "Contract offered — Pending EOS.\n\n" +
        "Your wage bid is locked for this player on the Expiring Contracts market. " +
        "Highest bid wins at season rollover (end of season). You cannot change the bid.\n\n" +
        wageNote
      );
    }
    return (
      "Final contract year (1 season left of a 3-season deal).\n\n" +
      "Cannot Transfer List or sell. They are on the Expiring Contracts market — other clubs (and you) may place one hidden wage bid; highest wins at season rollover.\n\n" +
      "Use Action → Offer wage bid to compete. No mid-season renew or expire — if nobody wins them at rollover they become a free agent (holding club receives market value).\n\n" +
      wageNote
    );
  }

  if (Number.isFinite(n) && n === 2) {
    return (
      "Two seasons remaining on this 3-season contract.\n\n" +
      "Next season becomes the final year — then no sales until you renew or they hit the expiry auction.\n\n" +
      "In December/January, Contract outlook warns you to consider selling while they can still be listed.\n\n" +
      wageNote
    );
  }

  if (Number.isFinite(n) && n >= 3) {
    return (
      "Full (or reset) 3-season contract still running.\n\n" +
      "You can list or sell (if not signed this season / not legacy). Watch the countdown toward the final year.\n\n" +
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
