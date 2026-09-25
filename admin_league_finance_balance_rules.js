/**
 * League finance balance — admin help (modular cards + hover tips).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260915-fin-balance-tips";

export const FIN_BALANCE_TIPS = {
  page:
    "Season ecosystem check: every club’s ops P&L (transfers, loans, fines & stadium purchases excluded). Best after Close Finances. Use Gap / club vs your target to tune prizes, TV, subsidies, wages, or tax.",
  target:
    "Desired average operating profit per club for this season (default ₿10m). Gap / club = target minus actual avg ops net.",
  run: "Aggregates season ledger categories for every club in the season (owned or vacant).",
  clubs: "How many clubs were included in this season’s finance set.",
  avgOps:
    "Mean ops net across clubs. Ops ignore transfers, loans, fines, and stadium purchases.",
  medianOps:
    "Middle club’s ops net (less skewed by a few extreme clubs than the average).",
  targetKpi: "The target average ops profit you set above.",
  gapClub:
    "Target minus avg ops net. Positive gap = clubs are under target (need more income or lower costs). Negative = over target.",
  gapTotal: "Gap / club × number of clubs — approximate league-wide tuning size.",
  hint: "Auto-written tuning suggestion from the gap vs target.",
  cats: "League-wide sums by ledger category. Transfers, loans, fines, and stadium purchases are shown but excluded from ops net.",
  opening:
    "Archived prior close, season opening, or starting-budget trail. — means none found (live Balance can still show cash).",
  gates: "Match gate receipts posted this season.",
  prizes: "League, cup, challenge, and related prize income.",
  tv: "TV revenue lines posted this season.",
  subsidies: "Government HG / Youth / Weak squad subsidies (usually ₿0 until EOS payout).",
  wages: "Player/manager wage bills (usually ₿0 until Close Finances).",
  stadium:
    "Stadium ops in the ecosystem: maintenance, expansions, refunds/penalties. Starting stadium purchases are excluded from ops.",
  taxFines: "Income tax and emergency tax (fines are excluded from ops and shown separately).",
  staff: "Manager salary, medical hires, contract fees/releases, and related staff lines.",
  opsNet:
    "Operating P&L for the club this season (excludes transfers, loans, fines, and stadium purchases).",
  transfers:
    "Net transfer market cash (excluded from ops). Large negatives usually mean net buying.",
  balance: "Live Club_Finances cash now — often starting money ± transfers, not ops health.",
  catGates: "Sum of gate receipts across all clubs.",
  catPrizes: "Sum of prize income across all clubs.",
  catTv: "Sum of TV revenue across all clubs.",
  catSubsidies: "Sum of government subsidies (often ₿0 before EOS pay).",
  catWages: "Sum of wage bills (often ₿0 before Close Finances).",
  catStadium: "Sum of stadium ops (maintenance / expansion) — included in ops net.",
  catStadiumPurchase: "Starting stadium purchases — excluded from ops net.",
  catTax: "Sum of income / emergency tax — included in ops net.",
  catFines: "Match / discipline fines (gov_fine_compensation) — excluded from ops net.",
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
    lead: `Every club in the season (owned or vacant). <b>Ops net</b> ignores transfers, loans, fines, and stadium purchases — those are shown separately so prize/wage tuning is not skewed by one-offs or market spend.`,
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
        tip: "Ops net is the ecosystem signal. Transfers, fines, stadium buys, and live Balance are cash noise — don’t use them to set prize tables.",
        items: [
          "<b>Ops net</b> = gates + prizes + TV + subsidies + wages + stadium ops + tax + staff + EOS ± admin/other.",
          "<b>Excluded from ops</b>: transfers, loans, fines (gov_fine_compensation), stadium purchases (infra_purchase).",
          "<b>Balance</b> is live club cash — often starting money ± transfers, not “healthy ops”.",
          "<b>Opening —</b> = no archived opening / starting-budget trail found (cash can still show in Balance).",
        ],
      },
      {
        heading: "Stadium & zeros",
        tip: "Stadium ops ₿0 usually means no maintenance/expansion posted. Stadium buy is excluded from ops. Wages / Subsidies / EOS ₿0 almost always means season-end posts have not run.",
        items: [
          "<b>Stadium ops</b> = maintenance / expansion (in ops). <b>Stadium buy</b> = starting purchase (excluded).",
          "Use Backfill vacant clubs for unowned league clubs missing stadium posts.",
          "<b>Wages / Subsidies / EOS ₿0</b> almost always means season-end posts have not run yet.",
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
