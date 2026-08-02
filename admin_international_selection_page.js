import { initAdminPage, primeAdminPageChrome } from "./admin_common.js";
import {
  refreshSelectionLive,
  wireNationSelectionControls,
} from "./admin_international_selection.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  wireNationSelectionControls();
  await refreshSelectionLive();
});
