import { supabase, initGlobal } from "./global.js";
import {
  loadInternationalNations,
  loadOwnerDraftOrder,
  loadSelectionWindow,
  loadMyNation,
  claimNation,
  renderNationFlag,
} from "./international.js";

function setStatus(msg, ok = true) {
  const el = document.getElementById("statusMsg");
  if (!el) return;
  el.textContent = msg;
  el.className = ok ? "ok" : "err";
}

function renderWindow(windowState, myPick, draft, nations) {
  const el = document.getElementById("windowInfo");
  if (!el) return;
  if (!windowState?.is_open) {
    el.innerHTML =
      '<span class="empty">Nation selection is closed. Admin can open the window when ready.</span>';
    return;
  }
  const mine =
    myPick && windowState.current_pick_rank === myPick
      ? ' <b style="color:#ff9900;">— your pick!</b>'
      : "";
  const draftSize =
    windowState.draft_order_size || draft.length || windowState.nations_total || nations.length || 60;
  const nationCount = windowState.nations_total || nations.length;
  el.innerHTML = `
    <b>Nation selection</b> is open · Pick #${windowState.current_pick_rank} of ${draftSize}
    · ${nationCount} nations available · ${windowState.nations_assigned || 0} assigned${mine}
  `;
}

function renderDraftBoard(draft, myClub, currentPick) {
  const el = document.getElementById("draftBoard");
  if (!el) return;
  if (!draft.length) {
    el.innerHTML = '<p class="empty">No owners in draft order yet.</p>';
    return;
  }
  const rows = draft
    .map((d) => {
      const cls = [
        d.pick_order === currentPick ? "current-pick" : "",
        d.club_short_name === myClub ? "me" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const nat = d.nation_code
        ? `${renderNationFlag({ code: d.nation_code, flag_emoji: d.flag_emoji, name: d.nation_name }, "sm")} ${d.nation_name}`
        : '<span class="empty">—</span>';
      const ownerLabel = d.owner_tag || d.owner_name || "—";
      const clubLabel = d.club_name || d.club_short_name;
      return `
        <tr class="${cls}">
          <td>${d.pick_order}</td>
          <td>${ownerLabel}</td>
          <td>${clubLabel}</td>
          <td>${Number(d.rank_points).toLocaleString("en-GB", { maximumFractionDigits: 2 })}</td>
          <td>${nat}</td>
        </tr>`;
    })
    .join("");
  el.innerHTML = `
    <table class="draft-board">
      <thead><tr><th>#</th><th>Owner</th><th>Club</th><th>Rank pts</th><th>Nation</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
}

function renderNationGrid(nations, windowState, myPick, myClub, draft) {
  const el = document.getElementById("nationGrid");
  const hint = document.getElementById("pickHint");
  if (!el) return;

  const open = windowState?.is_open;
  const myTurn = open && myPick && windowState.current_pick_rank === myPick;
  const alreadyPicked = draft.find(
    (d) => d.club_short_name === myClub && d.nation_code
  );

  if (hint) {
    if (!open) hint.textContent = "Selection is closed.";
    else if (alreadyPicked)
      hint.textContent = `You selected ${alreadyPicked.nation_name}. Waiting for other owners…`;
    else if (myTurn) hint.textContent = "Click a nation to claim it.";
    else hint.textContent = `Waiting for pick #${windowState?.current_pick_rank || "—"}.`;
  }

  el.innerHTML = nations
    .map((n) => {
      const taken = n.is_taken;
      const disabled = !open || !myTurn || taken;
      const cls = [
        "nat-pick-card",
        taken ? "taken" : "",
        disabled ? "disabled" : "",
        myTurn && !taken ? "my-turn" : "",
      ]
        .filter(Boolean)
        .join(" ");
      return `
        <div class="${cls}" data-code="${n.code}" title="${taken ? "Taken" : n.name}">
          <span class="flag">${renderNationFlag(n, "lg")}</span>
          <span class="name">${n.name}</span>
        </div>`;
    })
    .join("");

  el.querySelectorAll(".nat-pick-card:not(.taken):not(.disabled)").forEach((card) => {
    card.addEventListener("click", async () => {
      const code = card.dataset.code;
      if (!code || !confirm(`Claim ${code} as your national team?`)) return;
      setStatus("Claiming…");
      const res = await claimNation(code, supabase);
      if (res.error) {
        setStatus(res.error, false);
        return;
      }
      setStatus(`Nation ${code} claimed!`, true);
      setTimeout(() => location.reload(), 600);
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: clubRow } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user?.id)
    .maybeSingle();
  const myClub = clubRow?.ShortName || null;

  const [nations, draft, windowState, myNation] = await Promise.all([
    loadInternationalNations(supabase),
    loadOwnerDraftOrder(supabase),
    loadSelectionWindow(supabase),
    loadMyNation(supabase),
  ]);

  const myPickRow = draft.find((d) => d.club_short_name === myClub);
  const myPick = myPickRow?.pick_order ?? null;

  if (myNation?.code) {
    const btn = document.getElementById("myTeamBtn");
    if (btn) {
      btn.href = `national_team.html?nation=${encodeURIComponent(myNation.code)}`;
      btn.hidden = false;
    }
  }

  renderWindow(windowState, myPick, draft, nations);
  renderDraftBoard(draft, myClub, windowState?.current_pick_rank);
  renderNationGrid(nations, windowState, myPick, myClub, draft);
});
