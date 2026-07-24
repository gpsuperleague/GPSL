/**
 * Squad page owner-help tip copy (hover / focus).
 */

import { isContractFinalYear, isPesdbLegacyCard } from "./player_contracts.js";
import { isHgContractProtected } from "./squad_rules.js";

export const SQUAD_TIPS = {
  card:
    "Player card image — click to open the eFootball card on pesdb.net (external card database GPSL syncs from).",

  name:
    "Player name — click to open this player’s GPSL career page (appearances, goals, transfer history, clubs).",

  nation:
    "Player’s nationality. Used for home-grown (HG) counts when it matches your club’s nation.",

  position:
    "Registered playing position from the card. Used for squad balance and match selection.",

  age: "Current age. Home-grown contract protection for young HG players ends at age 24.",

  rating:
    "Overall rating (and calculated potential in brackets when shown). Pot. is GPSL’s formula — not always the raw pesdb max level.",

  apps: "Appearances for your club this GPSL season (competition matches counted on this page).",

  goals: "Goals scored for your club this GPSL season.",

  assists: "Assists for your club this GPSL season.",

  avg: "Average match rating this GPSL season (when recorded).",

  playstyle:
    "Card playstyle (e.g. Goal Poacher, Anchor Man). Affects how the player plays in eFootball; shown here for squad planning.",

  marketValue:
    "GPSL market value (MV). Floor for transfer bids and foreign sales. Releases / expire payouts often use MV or a % of MV.",

  status:
    "Current availability — transfer-listed, injured, suspended, yellow-card tally, etc. Stacked badges explain what’s blocking selection or sales.",

  action:
    "Player actions: Transfer List, sell abroad (uses a foreign-interest slot), renew/expire in the final contract year, medical consults, red-card appeals, captain/OooO roles, and voluntary releases when available.\n\nScroll sideways if the column is off-screen.",

  contractHeader:
    "Contract length + seasonal wage.\n\nStandard deals are 3 seasons. When 1 season remains (“Final year”), the player cannot be listed or sold — they enter the expiry wage auction unless legacy / young HG rules apply.",

  registration:
    "Squad registration rules for your club this season.\n\nAim for at least 24 contracted players from August, never more than 28, plus home-grown / U21 / star-cap rules. Failures can mean fines and emergency loans in August.",

  wageBillTitle:
    "Estimated seasonal wage bill for Close Finances — player contract wages plus manager salary (weekly × 52).",

  playerWages:
    "Sum of contracted player wages for the season. Posted when finances are closed for the GPSL month / season step.",

  managerSalary:
    "Your manager’s seasonal salary (weekly wage × 52). Included in the total wage bill on Finances.",

  totalWageBill:
    "Player wages + manager salary. Plan signings against this — wages hit the books at Close Finances.",

  manager:
    "Your club manager. Rating sets a season finish target for your division. Miss it and they may leave at season end; big/medium clubs can also face a forced player listing.\n\nSack / list only in June–August and January (with mid-spell rules). Sack costs half market value (once per season).",

  foreignInterest:
    "Foreign club sale slots left this season. Selling abroad at market value frees a squad place and can avoid overflow fines. Use Sell to foreign club in Action.",

  voluntaryRelease:
    "Voluntary releases left this season (max 3). You keep paying wages; the player is out until next season. Useful when you cannot sell.",

  newOwnerRelease:
    "First-season owner tools — limited free releases / listings while you settle into the club. Check the badge hint for what’s left and when the window is open.",
};

export function squadContractTip(player, clubNation) {
  const n = Number(player?.contract_seasons_remaining);
  const wageNote =
    "The lower line is this player’s seasonal contract wage (counts toward your wage bill).";

  if (isPesdbLegacyCard(player)) {
    if (isContractFinalYear(player)) {
      return (
        "Legacy card (no longer on pesdb.net) — final contract year.\n\n" +
        "Cannot be sold or listed. Not on the expiry wage auction. Use Action → Renew (1 season at a time) or Expire — release for MV.\n\n" +
        wageNote
      );
    }
    return (
      "Legacy card (removed from pesdb.net). Stays playable at your club but cannot be sold or listed until/unless a future sync restores the card.\n\n" +
      wageNote
    );
  }

  if (isContractFinalYear(player)) {
    if (isHgContractProtected(player, clubNation)) {
      return (
        "Final contract year — home-grown aged 23 or under.\n\n" +
        "Protected from the expiry wage auction. Use Action to renew (often same wage, fresh deal) or expire for MV. Cannot Transfer List or sell while in the final year.\n\n" +
        wageNote
      );
    }
    return (
      "Final contract year (1 season left of a 3-season deal).\n\n" +
      "Cannot Transfer List or sell. At season end they enter the hidden expiry wage auction (other clubs — and you — may bid once). Or use Action now to Renew (new 3 seasons) or Expire — release for MV.\n\n" +
      wageNote
    );
  }

  if (Number.isFinite(n) && n === 2) {
    return (
      "Two seasons remaining on this 3-season contract.\n\n" +
      "Next season becomes the final year — then no sales until you renew or they hit the expiry auction.\n\n" +
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
