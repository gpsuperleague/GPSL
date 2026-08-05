/**
 * Medical Room — section intro copy.
 */

export function getMedicalRoomIntros() {
  return {
    doctor: `Required. The doctor assesses injuries and must be hired before any specialist
        consultant (injury reduction) can be used. While hired, every new injury is shortened
        by <b>1 match</b> (out phase). Name &amp; gender assigned at random on hire.
        3-season contract, then retires.`,
    physio: `Up to <b>5</b> physios at <b>€3,000,000</b> each. Each reduces this club’s injury chance by <b>0.5%</b>.
        Name &amp; gender assigned at random on hire. 3-season contracts.`,
    consultants: `The doctor assesses each injury first. To shorten recovery, they refer the player to a
        <b>specialist consultant</b> — that spends one injury-reduction consult (−2 / −4 / −6 / −8 / −10 matches).
        One consult per injury. Same consults can also be used from
        <a href="club_prizes.html" style="color:#7ec8e8;">Rewards Centre</a>
        and the squad Action menu.`,
  };
}

export function renderMedicalRoomIntros() {
  const copy = getMedicalRoomIntros();
  const map = [
    ["medDoctorIntro", copy.doctor],
    ["medPhysioIntro", copy.physio],
    ["medConsultantsIntro", copy.consultants],
  ];
  for (const [id, html] of map) {
    const el = document.getElementById(id);
    if (el) el.innerHTML = html;
  }
}
