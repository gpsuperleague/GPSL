/**
 * Season challenges — page intro copy.
 */

export function getChallengesIntroHtml() {
  return `Hit each target for a cash prize (paid when the result is confirmed). The <b>first club to complete every
      challenge</b> in a window wins the big prize pack — cash, medical tokens, transfer discounts, and red-card
      appeal cards — auto-assigned to <a href="club_prizes.html">Rewards Centre</a> and announced in every inbox.
      Track your own progress on <a href="club_challenges.html">My Club → Challenges</a>.`;
}

export function renderChallengesIntro(rootEl) {
  const root =
    rootEl ||
    document.getElementById("challengesIntro") ||
    document.querySelector(".page-container > .meta");
  if (!root) return;
  root.innerHTML = getChallengesIntroHtml();
}
