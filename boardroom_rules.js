/**
 * Boardroom — committee / expectations intro copy.
 */

export function getBoardroomIntroHtml() {
  return `The board reviews <b>club finances</b>, <b>club performance</b>, <b>manager standing</b>,
        <b>prestige expectations</b>, <b>government subsidies</b>, and <b>league-position analysis</b> in one place.
        Ratings summarise cash health, on-pitch delivery (and player mood), and how likely the manager is to renew.
        Missing season expectation affects stadium gate fill and can trigger player transfer requests.`;
}

export function getBoardroomAnalysisIntroHtml() {
  return `Recent league finishes for the board’s review. Full season-by-season table and monthly chart remain on
        <a href="history.html">Club History</a>.`;
}

export function getBoardroomSubsidyIntroHtml() {
  return `Status from your current squad. Payouts post at season end when all league divisions
        have played <b>38/38</b> matches. HG bands pay separately (Quota ≤5, Flying 6–8, Pride 9+);
        status shows your highest tier. These also appear under <b>Pending</b> in
        <a href="finances_accounts.html">Season accounts</a> until paid.`;
}

export function getBoardroomFinanceIntroHtml() {
  return `Snapshot from the club books. Below: <b>finance</b>, <b>club performance</b>, and <b>manager</b> ratings for the committee.
        Advisory transfer budget is soft guidance only (does not block bids).
        Full detail on <a href="finances.html">Finances</a> · loans at the
        <a href="central_bank_counter.html">Central Bank</a>.`;
}

/** Shared A–E band from a 0–100 score. */
export function gradeFromBoardScore(score) {
  const s = Math.max(0, Math.min(100, Math.round(Number(score) || 0)));
  if (s >= 85) return { grade: "A", label: "Excellent", className: "excellent", score: s };
  if (s >= 70) return { grade: "B", label: "Strong", className: "strong", score: s };
  if (s >= 55) return { grade: "C", label: "Sound", className: "sound", score: s };
  if (s >= 40) return { grade: "D", label: "Fragile", className: "fragile", score: s };
  return { grade: "E", label: "Distressed", className: "distressed", score: s };
}

/**
 * Board finance confidence from cash health (balance-led, with EOS / wages / loans context).
 * @returns {{ grade: string, label: string, className: string, detail: string, summary: string, score: number }}
 */
export function computeBoardFinanceRating({
  balance = 0,
  projected = 0,
  wages = 0,
  loansOutstanding = 0,
  transferBudget = 0,
} = {}) {
  const bal = Number(balance) || 0;
  const proj = Number(projected) || 0;
  const wage = Number(wages) || 0;
  const loans = Number(loansOutstanding) || 0;
  const transfer = Number(transferBudget) || 0;

  let score = 50;

  if (bal >= 100_000_000) score += 30;
  else if (bal >= 50_000_000) score += 22;
  else if (bal >= 20_000_000) score += 12;
  else if (bal >= 5_000_000) score += 0;
  else if (bal >= 0) score -= 15;
  else score -= 30;

  if (proj < 0) score -= 12;
  else if (proj >= bal + 10_000_000) score += 6;
  else if (proj >= bal) score += 3;

  if (wage > 0) {
    const cover = bal / wage;
    if (cover >= 3) score += 6;
    else if (cover >= 1.5) score += 2;
    else if (cover < 0.75) score -= 12;
    else if (cover < 1) score -= 6;
  }

  if (loans <= 0) score += 4;
  else if (loans > bal) score -= 14;
  else if (loans > bal * 0.5) score -= 6;

  if (transfer <= 0 && bal < 10_000_000) score -= 4;
  else if (transfer >= 20_000_000) score += 3;

  const band = gradeFromBoardScore(score);

  const detailParts = [];
  if (bal < 5_000_000) detailParts.push("cash reserves are thin");
  else if (bal >= 100_000_000) detailParts.push("cash reserves are excellent");
  if (proj < 0) detailParts.push("projected end-of-season balance is negative");
  if (wage > 0 && bal < wage) detailParts.push("balance is below the seasonal wage bill");
  if (loans > bal && loans > 0) detailParts.push("outstanding loans exceed current balance");
  if (!detailParts.length) {
    detailParts.push("the committee is comfortable with the club’s cash position");
  }

  let summary = "Books look orderly.";
  if (band.score >= 85) summary = "Treasury is in rude health.";
  else if (band.score >= 70) summary = "Finances support the board’s ambitions.";
  else if (band.score >= 55) summary = "Cash position is workable if spending stays disciplined.";
  else if (band.score >= 40) summary = "The board wants tighter control of wages and loans.";
  else summary = "Distress flags — balance sheet pressure is hard to ignore.";

  return {
    ...band,
    summary,
    detail: `Board finance ${band.grade} (${band.label}, ${band.score}/100) — ${detailParts.join("; ")}.`,
  };
}

/**
 * Club on-pitch delivery vs prestige / season expectation.
 * @returns {{ grade: string, label: string, className: string, detail: string, summary: string, score: number, pending?: boolean }}
 */
export function computeClubPerformanceRating({
  ready = false,
  band = null,
  gap = 0,
  actualPos = null,
  expectedPos = null,
  tier = "",
} = {}) {
  if (!ready || !band) {
    return {
      grade: "—",
      label: "Pending",
      className: "sound",
      score: 0,
      pending: true,
      summary: "Too early for dressing-room chatter — wait for the first month’s fixtures.",
      detail:
        "Club performance rating unlocks after the first month’s league results vs expected points.",
    };
  }

  let score = 50;
  if (band === "on_target") score = 88;
  else if (band === "slight") score = 62;
  else if (band === "bad") score = 38;
  else if (band === "abysmal") score = 18;
  else score = 50;

  const gapN = Number(gap);
  if (Number.isFinite(gapN)) {
    if (gapN >= 8) score += 6;
    else if (gapN >= 3) score += 3;
    else if (gapN <= -12) score -= 8;
    else if (gapN <= -6) score -= 4;
  }

  const act = Number(actualPos);
  const exp = Number(expectedPos);
  if (Number.isFinite(act) && Number.isFinite(exp)) {
    const placeDelta = exp - act; // positive = better than expected
    if (placeDelta >= 3) score += 4;
    else if (placeDelta <= -4) score -= 6;
    else if (placeDelta <= -2) score -= 3;
  }

  if (tier === "big" && (band === "bad" || band === "abysmal")) score -= 4;
  if (tier === "low" && band === "on_target") score += 2;

  const graded = gradeFromBoardScore(score);

  const bandLabels = {
    on_target: "on target",
    slight: "a slight miss",
    bad: "a bad miss",
    abysmal: "an abysmal miss",
  };
  const bandPhrase = bandLabels[band] || band;

  let summary;
  if (band === "on_target") {
    summary =
      "Dressing room calm — players trust the project; no unrest rumours.";
  } else if (band === "slight") {
    summary =
      "Quiet murmurs in the squad — nothing loud yet, but the board wants a response.";
  } else if (band === "bad") {
    if (tier === "big" || tier === "medium") {
      summary =
        "Player rumblings: senior names are restless; a forced transfer request is a real risk at season end.";
    } else {
      summary =
        "Squad confidence is dipping and gate fill will drift — form needs to turn.";
    }
  } else {
    if (tier === "big") {
      summary =
        "Open unrest — top players may demand the market at archive; gate fill is under serious pressure.";
    } else if (tier === "medium") {
      summary =
        "Dressing-room fracture — mid-tier stars (74–78, over 21) could force a listing if this holds.";
    } else {
      summary =
        "Results are well off the board’s bar; no forced listing for low clubs, but the atmosphere is sour.";
    }
  }

  const detailParts = [`season delivery is ${bandPhrase}`];
  if (Number.isFinite(act) && Number.isFinite(exp)) {
    detailParts.push(`league ${act} vs expected ${exp}`);
  }
  if (Number.isFinite(gapN)) {
    detailParts.push(`points gap ${gapN >= 0 ? "+" : ""}${gapN.toFixed(1)}`);
  }

  return {
    ...graded,
    summary,
    detail: `Club performance ${graded.grade} (${graded.label}, ${graded.score}/100) — ${detailParts.join("; ")}.`,
  };
}

/**
 * Manager deal standing and renewal outlook for the board.
 * @returns {{ grade: string, label: string, className: string, detail: string, summary: string, score: number, vacant?: boolean }}
 */
export function computeManagerBoardRating({
  hasManager = false,
  targetMet = null,
  pendingRenewal = false,
  dealHits = 0,
  dealMisses = 0,
  seasonsRemaining = 0,
  seasonPosition = null,
  targetKind = null,
  targetValue = null,
  managerRating = null,
  archived = false,
} = {}) {
  if (!hasManager) {
    return {
      grade: "—",
      label: "Vacant",
      className: "fragile",
      score: 0,
      vacant: true,
      summary: "No manager in post — renew talk does not apply until someone is signed.",
      detail: "Appoint a manager via MGDB or the manager transfer market.",
    };
  }

  let score = 55;
  const hits = Number(dealHits) || 0;
  const misses = Number(dealMisses) || 0;
  const remaining = Number(seasonsRemaining) || 0;
  const mgrR = Number(managerRating);

  if (pendingRenewal) {
    score = 90 + Math.min(8, hits * 3);
  } else if (targetMet === true) {
    score = 78;
  } else if (targetMet === false) {
    score = 32;
  } else {
    score = 52;
  }

  score += Math.min(10, hits * 5);
  score -= Math.min(18, misses * 9);

  if (Number.isFinite(mgrR)) {
    if (mgrR >= 85) score += 4;
    else if (mgrR >= 78) score += 2;
    else if (mgrR < 70) score -= 3;
  }

  if (targetKind === "max_position" && targetValue != null && seasonPosition != null) {
    const pos = Number(seasonPosition);
    const tgt = Number(targetValue);
    if (Number.isFinite(pos) && Number.isFinite(tgt)) {
      if (pos <= tgt) score += 4;
      else if (pos <= tgt + 2) score -= 2;
      else if (pos <= tgt + 5) score -= 6;
      else score -= 12;
    }
  }

  if (archived) score -= 8;
  if (!pendingRenewal && remaining <= 1 && targetMet === false) score -= 4;
  if (!pendingRenewal && remaining <= 1 && targetMet === true) score += 3;

  const graded = gradeFromBoardScore(score);

  let summary;
  if (archived && pendingRenewal) {
    summary =
      "Renewal blocked — they have left the live catalog; keep until deal end for full MV or sack.";
  } else if (pendingRenewal) {
    summary =
      "Renewal outlook: high — they earned another deal; renew in June/July or lose them for market value.";
  } else if (targetMet === true && remaining >= 1) {
    summary =
      "Renewal outlook: favourable — on target this season; a hit keeps the door open at deal end.";
  } else if (targetMet === true && remaining <= 0) {
    summary =
      "Renewal outlook: strong if process confirms the hit — board will want continuity.";
  } else if (targetMet === false && misses >= 1) {
    summary =
      "Renewal outlook: poor — another miss ends the deal; they leave at MV with a 2-season rehire ban.";
  } else if (targetMet === false) {
    summary =
      "Renewal outlook: at risk — currently off the deal target; need a turnaround before season close.";
  } else if (hits > 0 && misses === 0) {
    summary =
      "Renewal outlook: promising — already banked a hit on this deal; stay on course.";
  } else {
    summary =
      "Renewal outlook: wait and see — not enough league evidence yet to call the deal.";
  }

  const detailParts = [];
  if (pendingRenewal) detailParts.push("pending owner renewal");
  else if (targetMet === true) detailParts.push("live on target");
  else if (targetMet === false) detailParts.push("live off target");
  else detailParts.push("target status pending");
  if (hits + misses > 0) detailParts.push(`deal record ${hits} hit · ${misses} miss`);
  if (remaining > 0 && !pendingRenewal) {
    detailParts.push(`${remaining} season${remaining === 1 ? "" : "s"} left on deal`);
  }
  if (Number.isFinite(mgrR)) detailParts.push(`rating ${mgrR}`);

  return {
    ...graded,
    summary,
    detail: `Manager standing ${graded.grade} (${graded.label}, ${graded.score}/100) — ${detailParts.join("; ")}.`,
  };
}

export function getBoardroomAgendaCards() {
  return [
    {
      heading: "Board ratings",
      body: "Finance, club performance, and manager standing — with renewal outlook and dressing-room mood.",
    },
    {
      heading: "Finances",
      body: "Balance, wage bill, advisory transfer budget, projected EOS, and Central Bank loans.",
    },
    {
      heading: "Club expectation",
      body: "Prestige sets the baseline finish. Medium and low clubs can see the bar rise with a strong manager.",
    },
    {
      heading: "Season delivery",
      body: "Live table vs expected points — on target, slight, bad, or abysmal miss.",
    },
    {
      heading: "Manager deal",
      body: "2-season contracts. Renew if they hit in at least one season; miss both and they leave.",
    },
    {
      heading: "Subsidies",
      body: "Homegrown, Youth, and Weak squad bonus status from the current squad.",
    },
    {
      heading: "Analysis",
      body: "Final league position over the last two seasons for board review.",
    },
  ];
}

export function renderBoardroomIntro() {
  const intro = document.getElementById("boardIntro");
  if (intro) intro.innerHTML = getBoardroomIntroHtml();

  const subsidyIntro = document.getElementById("boardSubsidyIntro");
  if (subsidyIntro) subsidyIntro.innerHTML = getBoardroomSubsidyIntroHtml();

  const financeIntro = document.getElementById("boardFinanceIntro");
  if (financeIntro) financeIntro.innerHTML = getBoardroomFinanceIntroHtml();

  const analysisIntro = document.getElementById("boardAnalysisIntro");
  if (analysisIntro) analysisIntro.innerHTML = getBoardroomAnalysisIntroHtml();

  const agenda = document.getElementById("boardAgenda");
  if (!agenda) return;
  agenda.innerHTML = getBoardroomAgendaCards()
    .map(
      (card) => `
      <div class="board-agenda-card">
        <h3>${card.heading}</h3>
        <p>${card.body}</p>
      </div>`
    )
    .join("");
}
