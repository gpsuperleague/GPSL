-- =============================================================================
-- Finance check (read-only): does every club's bank balance match its ledger,
-- and is every money type posted this season shown on the Finances page?
--
-- Part A — per club: balance now vs (opening balance + this season's ledger).
--          Drift ≠ 0 means money moved without a ledger line (or a ledger
--          line was written without moving money).
-- Part B — every entry_type posted this season, with totals, and whether the
--          Finances page has a line for it (else it lands in "Unmapped").
--
-- Changes nothing. Safe to re-run.
-- =============================================================================

DROP TABLE IF EXISTS _fin_report;
CREATE TEMP TABLE _fin_report (
  sort int,
  part text,
  club text,
  item text,
  amount numeric,
  note text
);

DROP TABLE IF EXISTS _fin_season;
CREATE TEMP TABLE _fin_season AS
SELECT s.id AS season_id, s.label AS season_label
FROM public.competition_seasons s
WHERE s.is_current = true
ORDER BY s.id DESC
LIMIT 1;

-- Part A ----------------------------------------------------------------------
INSERT INTO _fin_report
SELECT
  CASE WHEN x.opening IS NULL THEN 2 WHEN abs(x.drift) >= 1 THEN 1 ELSE 3 END,
  'A balance vs ledger',
  x.club,
  'balance ' || to_char(x.balance, 'FM999,999,999,990')
    || ' | opening ' || coalesce(to_char(x.opening, 'FM999,999,999,990'), '?')
    || ' | ledger ' || to_char(x.ledger_sum, 'FM999,999,999,990'),
  x.drift,
  CASE
    WHEN x.opening IS NULL THEN 'No archived closing balance from last season (new club?) — drift not checkable'
    WHEN abs(x.drift) >= 1 THEN 'MISMATCH — bank balance does not equal opening + ledger'
    ELSE 'OK'
  END
FROM (
  SELECT
    f.club_name AS club,
    f.balance::numeric AS balance,
    prev.closing_balance AS opening,
    coalesce(l.ledger_sum, 0) AS ledger_sum,
    f.balance::numeric - (prev.closing_balance + coalesce(l.ledger_sum, 0)) AS drift
  FROM public."Club_Finances" f
  JOIN public."Clubs" c ON c."ShortName" = f.club_name
  CROSS JOIN _fin_season s
  LEFT JOIN LATERAL (
    SELECT a.closing_balance
    FROM public.competition_club_finance_season_archive a
    WHERE a.club_short_name = f.club_name
      AND a.season_id < s.season_id
    ORDER BY a.season_id DESC
    LIMIT 1
  ) prev ON true
  LEFT JOIN LATERAL (
    SELECT sum(l.amount) AS ledger_sum
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = f.club_name
      AND l.season_id = s.season_id
  ) l ON true
  WHERE c.owner_id IS NOT NULL
     OR coalesce(l.ledger_sum, 0) <> 0
) x;

-- Part B ----------------------------------------------------------------------
INSERT INTO _fin_report
SELECT
  CASE WHEN m.t IS NULL THEN 4 ELSE 5 END,
  'B money types this season',
  count(DISTINCT l.club_short_name)::text || ' clubs',
  l.entry_type || ' (' || count(*) || ' rows)',
  sum(l.amount),
  CASE WHEN m.t IS NULL
       THEN 'NOT ON FINANCES PAGE — shows under "Unmapped ledger"'
       ELSE 'shown on Finances page' END
FROM public.competition_finance_ledger l
JOIN _fin_season s ON s.season_id = l.season_id
LEFT JOIN unnest(ARRAY[
  'transfer_sale','transfer_foreign_sale','transfer_overflow_release','contract_expiry_compensation',
  'new_owner_release','special_auction_fee','special_auction_prize','transfer_purchase',
  'transfer_agent_fee','gate_league_home','gate_cup_share','gate_friendlies','gate_match_video',
  'prize','prize_league','prize_cup','prize_challenge','tv_revenue','commercial_sponsorship',
  'commercial_advertising','commercial_merchandise','infra_maintenance','infra_purchase',
  'infra_expansion','infra_expansion_refund','infra_expansion_penalty','gov_fine_compensation','gov_hg_subsidy','gov_youth_subsidy','gov_bnb_subsidy',
  'gov_emergency_tax','gov_income_tax','wage_squad','wage_fan_favourite_subsidy',
  'wage_renewal_34plus','wage_star_tax','staff_manager_salary','medical_doctor_hire',
  'medical_physio_hire','contract_signing_offer','contract_release_comp',
  'contract_release_comp_received','contract_termination','eos_debt_interest','eos_ffp_charge',
  'eos_balance_interest','eos_injection','admin_one_off_injection','adjustment',
  'admin_purchase_payment','loan_drawdown','loan_repayment_principal','loan_interest_payment'
]) AS m(t) ON m.t = l.entry_type
GROUP BY l.entry_type, m.t;

SELECT r.part, r.club, r.item, r.amount, r.note,
       (SELECT season_label FROM _fin_season) AS season
FROM (SELECT 1) one
LEFT JOIN _fin_report r ON true
ORDER BY r.sort, abs(r.amount) DESC NULLS LAST, r.club;
