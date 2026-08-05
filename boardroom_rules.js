/**
 * Boardroom — committee / expectations intro copy.
 */

export function getBoardroomIntroHtml() {
  return `The board reviews <b>club prestige expectations</b> and the <b>manager’s deal target</b> in one place.
        Missing season expectation affects stadium gate fill and can trigger player transfer requests.
        Manager targets are reviewed each season of a 2-season deal.`;
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
  ];
}

export function renderBoardroomIntro() {
  const intro = document.getElementById("boardIntro");
  if (intro) intro.innerHTML = getBoardroomIntroHtml();

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
