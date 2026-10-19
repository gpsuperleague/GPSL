/**
 * Medical Room — section intro copy.
 */

export function getMedicalRoomIntros() {
  return {
    doctor: `Required. The doctor assesses injuries and must be hired before any specialist
        consultant (injury reduction) can be used. While hired, every new injury is shortened
        by <b>1 match</b> (out phase). Name &amp; gender assigned at random on hire.
        3-season contract, then retires.`,
    physio: `Fixed ladder — hire grades <b>1 → 5</b> in order (each unlocks the next).
        <b>1</b> Trainee −0.2% (₿500k) · <b>2</b> Physio −0.35% (₿750k) · <b>3</b> Senior −0.6% (₿1.25m) ·
        <b>4</b> Advanced −1% (₿2m) · <b>5</b> Consultant −2% (₿4m). Full set <b>−4.15%</b> for <b>₿8.5m</b>.
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
