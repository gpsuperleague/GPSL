/**
 * League finance balance — admin help (modular cards + hover tips).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260915-fin-balance-tips";

export const FIN_BALANCE_TIPS = {
  page:
    "Season ecosystem check: every club’s ops P&L (transfers & loans excluded). Best after Close Finances. Use Gap / club vs your target to tune prizes, TV, subsidies, wages, or tax.",
  target:
    "Desired average operating profit per club for this season (default ₿10m). Gap / club = target minus actual avg ops net.",
  run: "Aggregates season ledger categories for every club in the season (owned or vacant).",
  clubs: "How many clubs were included in this season’s finance set.",
  avgOps:
    "Mean ops net across clubs. Ops ignore transfers and Central Bank loans.",
  medianOps:
    "Middle club’s ops net (less skewed by a few extreme clubs than the average).",
  targetKpi: "The target average ops profit you set above.",
  gapClub:
    "Target minus avg ops net. Positive gap = clubs are under target (need more income or lower costs). Negative = over target.",
  gapTotal: "Gap / club × number of clubs — approximate league-wide tuning size.",
  hint: "Auto-written tuning suggestion from the gap vs target.",
  cats: "League-wide sums by ledger category. Transfers and loans are shown but excluded from ops net.",
  opening:
    "Archived prior close, season opening, or starting-budget trail. — means none found (live Balance can still show cash).",
  gates: "Match gate receipts posted this season.",
  prizes: "League, cup, challenge, and related prize income.",
  tv: "TV revenue lines posted this season.",
  subsidies: "Government HG / Youth / Weak squad subsidies (usually ₿0 until EOS payout).",
  wages: "Player/manager wage bills (usually ₿0 until Close Finances).",
  stadium:
    "Infra: expansion, purchase, maintenance, refunds. ₿0 = nothing posted yet (maintenance often waits for Close Finances).",
  taxFines: "Income tax, emergency tax, and fine/compensation lines.",
  staff: "Manager salary, medical hires, contract fees/releases, and related staff lines.",
  opsNet:
    "Operating P&L for the club this season (excludes transfers and loans).",
  transfers:
    "Net transfer market cash (excluded from ops). Large negatives usually mean net buying.",
  balance: "Live Club_Finances cash now — often starting money ± transfers, not ops health.",
  catGates: "Sum of gate receipts across all clubs.",
  catPrizes: "Sum of prize income across all clubs.",
  catTv: "Sum of TV revenue across all clubs.",
  catSubsidies: "Sum of government subsidies (often ₿0 before EOS pay).",
  catWages: "Sum of wage bills (often ₿0 before Close Finances).",
  catStadium: "Sum of stadium/infra ledger lines (expansions can dominate mid-season).",
  catTax: "Sum of tax and fine lines across all clubs.",
  catStaff: "Sum of staff / medical / contract-fee style lines.",
  catEos: "End-of-season interest, FFP, and related close lines (₿0 until Close Finances).",
  catAdmin: "Admin adjustments and one-off injections.",
  catOther: "Other operating lines not in the main buckets.",
  catTransfers: "Net transfers league-wide — excluded from ops net.",
  catLoans: "Net loan drawdowns/repayments — excluded from ops net.",
};

export function getLeagueFinanceBalanceRules() {
  return {
    title: "How to use this page",
    lead: `Every club in the season (owned or vacant). <b>Ops net</b> ignores transfers and Central Bank loans — those are shown separately so prize/wage tuning is not skewed by market spend.`,
    cards: [
      {
        heading: "When to trust it",
        tip: "Best after Close Finances. Mid-season wages/subsidies/EOS at ₿0 means the picture is incomplete — don’t redesign prizes from that alone.",
        items: [
          "<b>Best after Close Finances</b> — wages, stadium maintenance, and EOS lines are posted.",
          "Mid-season is fine for gates / prizes / TV progress, but <b>Wages / Subsidies / EOS at ₿0</b> means the picture is incomplete.",
          "Do not redesign prize tables from a mid-season run alone.",
        ],
      },
      {
        heading: "How to decide",
        tip: "Set healthy profit goal → Run → read the verdict box (What this means / What to do). Shortfall = add prizes/TV/subsidies or cut costs.",
        items: [
          "Set <b>Healthy profit goal per club</b> (default ₿10m).",
          "Run analysis → read the <b>verdict box</b> first (plain English + actions).",
          "<b>Shortfall</b> → raise prizes / TV / subsidies, or ease wage / tax pressure.",
          "<b>Too rich</b> → cool prizes / TV / subsidies, or raise wage / tax pressure.",
        ],
      },
      {
        heading: "Read the columns",
        tip: "Ops net is the ecosystem signal. Transfers and live Balance are cash noise — don’t use them to set prize tables.",
        items: [
          "<b>Ops net</b> = gates + prizes + TV + subsidies + wages + stadium + tax/fines + staff + EOS ± admin/other.",
          "<b>Transfers</b> and <b>Loans</b> are excluded from ops (cash noise, not ecosystem income).",
          "<b>Balance</b> is live club cash — often starting money ± transfers, not “healthy ops”.",
          "<b>Opening —</b> = no archived opening / starting-budget trail found (cash can still show in Balance).",
        ],
      },
      {
        heading: "Stadium & zeros",
        tip: "Stadium ₿0 usually means no infra posted yet. Use Backfill vacant clubs for unowned league clubs. Wages / Subsidies / EOS ₿0 almost always means season-end posts have not run.",
        items: [
          "<b>Stadium ₿0</b> = no infra ledger yet (no expansion/purchase, and maintenance not posted until Close Finances).",
          "Large stadium figures are usually expansions / purchase charges for clubs that built.",
          "<b>Vacant clubs:</b> use <b>Backfill vacant clubs</b> to post stadium purchase + doctor hire.",
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
