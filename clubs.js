import { supabase, initGlobal } from "./global.js";

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubs();
});

async function loadClubs() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("*")
    .neq("ShortName", "FOREIGN")
    .order("Club", { ascending: true });

  if (error) {
    console.error(error);
    return;
  }

  const container = document.getElementById("clubs");

  data.forEach((club) => {
    const div = document.createElement("div");
    div.className = "club-card";

    div.onclick = () => {
      window.location.href = `club.html?club=${encodeURIComponent(club.Club)}`;
    };

    div.innerHTML = `
      <img src="images/club_badges/${club.ShortName}.png" alt="${club.Club} badge">
      <div>${club.Club}</div>
    `;

    container.appendChild(div);
  });
}
