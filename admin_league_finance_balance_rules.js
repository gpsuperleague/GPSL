/**
 * League finance balance — admin help (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260915-fin-balance";

export function getLeagueFinanceBalanceRules() {
  return {
    title: "How to use this page",
    lead: `Every club in the season (owned or vacant). <b>Ops net</b> ignores transfers and Central Bank loans — those are shown separately so prize/wage tuning is not skewed by market spend.`,
    cards: [
      {
        heading: "When to trust it",
        items: [
          "<b>Best after Close Finances</b> — wages, stadium maintenance, and EOS lines are posted.",
          "Mid-season is fine for gates / prizes / TV progress, but <b>Wages / Subsidies / EOS at ₿0</b> means the picture is incomplete.",
          "Do not redesign prize tables from a mid-season run alone.",
        ],
      },
      {
        heading: "How to decide",
        items: [
          "Set <b>Target avg ops profit</b> (default ₿10m per club).",
          "Run analysis → read <b>Gap / club</b> and the amber hint box.",
          "<b>Under target</b> → raise prizes / TV / subsidies, or ease wage / tax pressure by about that gap.",
          "<b>Over target</b> → cool prizes / TV / subsidies, or raise wage / tax pressure.",
        ],
      },
      {
        heading: "Read the columns",
        items: [
          "<b>Ops net</b> = gates + prizes + TV + subsidies + wages + stadium + tax/fines + staff + EOS ± admin/other.",
          "<b>Transfers</b> and <b>Loans</b> are excluded from ops (cash noise, not ecosystem income).",
          "<b>Balance</b> is live club cash — often starting money ± transfers, not “healthy ops”.",
          "<b>Opening —</b> = no archived opening / starting-budget trail found (cash can still show in Balance).",
        ],
      },
      {
        heading: "Stadium & zeros",
        items: [
          "<b>Stadium ₿0</b> = no infra ledger yet (no expansion/purchase, and maintenance not posted until Close Finances).",
          "Large stadium figures are usually expansions / purchase charges for clubs that built.",
          "<b>Wages / Subsidies / EOS ₿0</b> almost always means those season-end posts have not run yet.",
        ],
      },
    ],
  };
}

export function renderLeagueFinanceBalanceRules(rootEl) {
  const root =
    rootEl || document.getElementById("finBalRules");
  renderRulesPanel(root, getLeagueFinanceBalanceRules());
}
