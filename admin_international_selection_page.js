import { initAdminPage, primeAdminPageChrome } from "./admin_common.js";
import {
  refreshSelectionLive,
  wireNationSelectionControls,
} from "./admin_international_selection.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  wireNationSelectionControls();
  await refreshSelectionLive();
});
