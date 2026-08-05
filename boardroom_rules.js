/**
 * Boardroom — committee / expectations intro copy.
 */

export function getBoardroomIntroHtml() {
  return `The board reviews <b>club prestige expectations</b>, the <b>manager’s deal target</b>, and
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

export function getBoardroomAgendaCards() {
  return [
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
