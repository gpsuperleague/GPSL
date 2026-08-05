/**
 * Boardroom — committee / expectations intro copy.
 */

export function getBoardroomIntroHtml() {
  return `The board reviews <b>club finances</b>, <b>prestige expectations</b>, the <b>manager’s deal target</b>, and
        <b>government subsidies</b> in one place.
        Missing season expectation affects stadium gate fill and can trigger player transfer requests.
        Manager targets are reviewed each season of a 2-season deal.`;
}

export function getBoardroomSubsidyIntroHtml() {
  return `Status from your current squad. Payouts post at season end when all league divisions
        have played <b>38/38</b> matches. HG bands pay separately (Quota ≤5, Flying 6–8, Pride 9+);
        status shows your highest tier. These also appear under <b>Pending</b> in
        <a href="finances_accounts.html">Season accounts</a> until paid.`;
}

export function getBoardroomFinanceIntroHtml() {
  return `Snapshot from the club books. Advisory transfer budget is soft guidance only (does not block bids).
        Full detail on <a href="finances.html">Finances</a> · loans at the
        <a href="central_bank_counter.html">Central Bank</a>.`;
}

/**
 * Board finance confidence from cash health (balance-led, with EOS / wages / loans context).
 * @returns {{ grade: string, label: string, className: string, detail: string, score: number }}
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

  score = Math.max(0, Math.min(100, Math.round(score)));

  let grade;
  let label;
  let className;
  if (score >= 85) {
    grade = "A";
    label = "Excellent";
    className = "excellent";
  } else if (score >= 70) {
    grade = "B";
    label = "Strong";
    className = "strong";
  } else if (score >= 55) {
    grade = "C";
    label = "Sound";
    className = "sound";
  } else if (score >= 40) {
    grade = "D";
    label = "Fragile";
    className = "fragile";
  } else {
    grade = "E";
    label = "Distressed";
    className = "distressed";
  }

  const detailParts = [];
  if (bal < 5_000_000) detailParts.push("cash reserves are thin");
  else if (bal >= 100_000_000) detailParts.push("cash reserves are excellent");
  if (proj < 0) detailParts.push("projected end-of-season balance is negative");
  if (wage > 0 && bal < wage) detailParts.push("balance is below the seasonal wage bill");
  if (loans > bal && loans > 0) detailParts.push("outstanding loans exceed current balance");
  if (!detailParts.length) {
    detailParts.push("the committee is comfortable with the club’s cash position");
  }

  return {
    grade,
    label,
    className,
    score,
    detail: `Board rating ${grade} (${label}, ${score}/100) — ${detailParts.join("; ")}.`,
  };
}

export function getBoardroomAgendaCards() {
  return [
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
  ];
}

export function renderBoardroomIntro() {
  const intro = document.getElementById("boardIntro");
  if (intro) intro.innerHTML = getBoardroomIntroHtml();

  const subsidyIntro = document.getElementById("boardSubsidyIntro");
  if (subsidyIntro) subsidyIntro.innerHTML = getBoardroomSubsidyIntroHtml();

  const financeIntro = document.getElementById("boardFinanceIntro");
  if (financeIntro) financeIntro.innerHTML = getBoardroomFinanceIntroHtml();

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
