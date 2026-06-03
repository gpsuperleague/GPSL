# GPSL finances — line items & central bank (design memory)

**Status:** Phase 1 in progress — `supabase/sql/central_bank_phase1.sql`, expanded `finances.html`. Loans & full Excel rows still planned.

**Currency:** ₿ everywhere in the app (Excel mixed £/$ — do not replicate).

**Today:** `Club_Finances.balance` is updated directly by transfers, gates, foreign sales, etc. `competition_finance_ledger` records some competition flows only. Most Excel rows have **no** ledger line yet.

**Target:** **GPSL Central Bank** as the system counterparty — club ↔ bank for almost all money movement; optional **loans** with interest.

---

## 1. Finance line descriptions (from Excel workbook)

Grouped like the spreadsheet. Each row should eventually map to a **ledger `entry_type`** (or loan event) + human **description** template.

### 1.1 Club identity & opening position

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `opening_balance` | Opening balance (start of season / after admin reset) | — | Snapshot; may differ from live `Club_Finances.balance` if mid-season |
| `admin_one_off_injection` | One-off injection (manual / central bank credit) | Credit club | “Links” column in Excel |
| `admin_purchase_payment` | Purchase payment (manual adjustment) | Debit or credit | Admin-only; clarify sign convention |

### 1.2 Player transfers

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `transfer_sale` | Player sale (fee received) | Credit club | From `Transfer_History` as seller |
| `transfer_purchase` | Player purchase (fee paid) | Debit club | From `Transfer_History` as buyer |
| `transfer_agent_fee` | Agent fee on transfer | Debit club | `Transfer_History.agent_fee` |
| `transfer_future_fee` | Future fee (installment / obligation) | Debit club (or accrual) | Excel “Future Fees”; may be scheduled |
| `transfer_overflow_release` | Squad overflow release (MV credit) | Credit club | Foreign sale or MV free-agent release |
| `transfer_foreign_sale` | Foreign club sale (overflow slot) | Credit club | `transfer_sale_note = squad_overflow` |

### 1.3 Prize money & revenue

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `gate_league_home` | Gate receipts — league home fixture | Credit club | **Live** in `competition_finance_ledger` |
| `gate_cup_share` | Gate receipts — cup 50% share | Credit club | **Live** in ledger |
| `prize_league` | League prize money | Credit club | Ledger `prize` or split by competition |
| `prize_cup` | Cup prize money | Credit club | |
| `prize_challenge` | Challenge prize money | Credit club | |
| `tv_revenue` | TV revenue | Credit club | Season / fixture rules TBD |
| `prize` | Prize money (generic) | Credit club | **Live** today (undifferentiated) |

### 1.4 Infrastructure (stadium & facilities)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `infra_maintenance` | Stadium / infrastructure maintenance | Debit club | Recurring? Tie to `Clubs` / stadium level |
| `infra_expansion` | Stadium expansion | Debit club | One-off build costs |
| `infra_upgrade` | Facility upgrade | Debit club | |
| `infra_training` | Training facility cost | Debit club | |

### 1.5 Government / league (subsidies & tax)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `gov_fine_compensation` | Fines & compensation | Debit or credit | Discipline / settlements |
| `gov_min_subsidy` | Minimum subsidy | Credit club | League floor funding |
| `gov_youth_subsidy` | Youth subsidy | Credit club | |
| `gov_bmr_subsidy` | “BMR” subsidy (not bought) | Credit club | Excel label; define rule in spec |
| `gov_emergency_tax` | Emergency tax | Debit club | One-off |
| `gov_income_tax` | Income tax | Debit club | Season % of profit or flat |

### 1.6 Player upkeep (wages & contract costs)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `wage_squad` | Squad wages (season / period total) | Debit club | Sum `contract_wage` or `calculate_player_wage_for_club` |
| `wage_renewal_34plus` | 34+ contract renewal cost | Debit club | Final-year / age rule |
| `wage_star_tax` | Star tax | Debit club | High-rated player surcharge (rules TBD) |

### 1.7 Staff & contracts (non-wage)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `staff_manager_salary` | Manager salary | Debit club | Per season |
| `contract_signing_offer` | Contract offers (signing) | Debit club | New signings / bid wins |
| `contract_release_comp` | Contract release (compensation paid) | Debit club | |
| `contract_release_comp_received` | Contract release (compensation received) | Credit club | Excel green column |
| `contract_termination` | Contract terminations | Debit or credit | |

### 1.8 End of season

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `eos_debt_interest` | End of season debt interest | Debit club | **Loans** — see §3 |
| `eos_ffp_charge` | End of season FFP charge | Debit club | Financial fair play |
| `eos_injection` | End of season injection | Credit club | League / bank bailout |

### 1.9 Balance summary (UI only, not ledger types)

| Field | Description |
|-------|-------------|
| `balance_current` | Current balance (`Club_Finances.balance`) |
| `balance_predicted_eos` | Predicted end-of-season balance (model) |
| `balance_predicted_next` | Predicted next season opening (model) |

---

## 2. Central bank — core idea

**GPSL Central Bank** (`GPSL_BANK` or `CENTRAL`) is not a playable club. It is the **counterparty** for double-sided money movement.

### 2.1 Principles

1. **Every material club cash movement** creates **two legs**: club account ±₿, bank account ∓₿ (sum zero across the league + bank).
2. **Club_Finances.balance** remains the club’s **spendable** balance (what transfers check today), updated only via **bank-posted** functions — no more ad-hoc `UPDATE Club_Finances` scattered in engines without a ledger row.
3. **competition_finance_ledger** (or successor **`club_finance_ledger`**) stores **club-side** lines with `entry_type` from §1; bank side can mirror in **`bank_ledger`** or metadata `counterparty: 'GPSL_BANK'`.
4. **Admin** acts as bank operator: injections, fines, manual adjustments, loan approval.

### 2.2 Suggested tables (future SQL)

| Table | Purpose |
|-------|---------|
| `gpsl_bank_account` | Singleton (or per-season) bank reserves, total loan book, policy rates |
| `club_finance_ledger` | All club lines (replaces/extends `competition_finance_ledger`) |
| `bank_ledger` | Optional mirror of bank-side entries |
| `club_loans` | Active loan: club, principal, rate, start, status |
| `club_loan_schedule` | Installments: due date, principal portion, interest portion, paid flag |
| `club_loan_payments` | Actual payments linked to ledger rows |

### 2.3 Posting pattern (example)

**Club buys player for ₿ 10M:**

- Club: `transfer_purchase` **−10M**
- Bank: receives **+10M** (seller club gets `transfer_sale` **+10M** — bank is not in the middle of club-to-club; only **club ↔ bank** for league-operated flows; **club ↔ club** transfers may be net-zero pair without bank, or bank as escrow — **decide one model**)

**Recommended models:**

- **A — Bank as league treasury:** Subsidies, taxes, prizes, gates, loans → club ↔ bank. **Club-to-club transfers** stay direct (buyer −, seller +) as today.
- **B — Bank as escrow:** All transfers flow buyer → bank → seller (heavier, full audit trail).

Default recommendation: **Model A** for subsidies/tax/loans/gates; keep **direct club-to-club** for transfer engine unless you want full traceability.

### 2.4 Functions to centralise (migrate over time)

Replace direct balance updates in:

- `transferengine_accept_sale` / `accept_draft_sale`
- `sell_to_foreign_club` / `player_release_from_club` (overflow)
- `competition_credit_club_balance` / gate settlement
- `special_auctions` settlement
- Admin adjustments

With: `post_club_ledger(p_club, p_entry_type, p_amount, p_description, p_metadata)` → updates `Club_Finances` + ledger (+ bank leg if applicable).

---

## 3. Loans & interest

### 3.1 Product rules (to confirm with spreadsheet)

| Term | Proposal |
|------|----------|
| **Who lends** | GPSL Central Bank only (admin approves or auto-rules) |
| **Principal** | Lump sum credited to club (`loan_drawdown`) |
| **Interest** | Fixed % per season or per matchday period; Excel “End Season Debt Interest” |
| **Repayment** | Scheduled installments and/or EOS lump sum |
| **Default** | Block transfers? Admin penalty? |

### 3.2 Ledger / event types for loans

| Code | Description | Direction |
|------|-------------|-----------|
| `loan_drawdown` | Loan principal paid to club | Credit club (bank −reserve) |
| `loan_repayment_principal` | Principal repayment | Debit club |
| `loan_interest_payment` | Interest payment (matchday or EOS) | Debit club |
| `loan_interest_accrual` | Interest accrued (optional, if not cash each period) | Memo only or debit on accrual |
| `loan_default_fee` | Penalty on default | Debit club |

### 3.3 Interest timing (align with Excel)

- **In-season:** optional small matchday interest (if loan outstanding).
- **End of season:** `eos_debt_interest` — charge on **outstanding principal × rate** (and/or unpaid accrued).
- Posting runs in **season rollover** job (same window as contract tick / wage bill).

### 3.4 UI (later)

- `finances.html`: **Loans** panel — outstanding principal, rate, next payment, history.
- Admin: approve loan, set rate, write off, restructure.

---

## 4. `finances.html` overhaul (after bank foundation)

1. **Summary** — current balance, loan outstanding, net season flow.
2. **Income / costs** — collapsible sections using §1 codes (green/red like Excel).
3. **Ledger** — filter by category; export CSV.
4. **Loans** — if `club_loans` row exists.
5. **Projections** — predicted EOS / next season (read-only formulas).

---

## 5. Implementation order (suggested)

1. **Spec sign-off** — Model A vs B; loan rules; which Excel rows are v1.
2. **`club_finance_ledger` + `post_club_ledger`** — extend entry types; backfill gates/transfers for current season.
3. **`gpsl_bank_account` + bank legs** for subsidies/tax/admin only.
4. **`club_loans` + interest job** — drawdown, schedule, EOS interest.
5. **`finances.html`** — Phase A UI reading ledger + transfers + wages; then loans panel.

---

## 6. Quick reference — live today vs planned

| Area | Live today | Planned |
|------|------------|---------|
| Balance | `Club_Finances` | Same, fed only via ledger poster |
| Gates / some prizes | `competition_finance_ledger` | Merge into unified ledger |
| Transfers | Balance only | `transfer_sale` / `transfer_purchase` rows |
| Wages | Calculated on squad, not billed | `wage_squad` season charge |
| Infra / tax / subsidies | — | Bank-posted types |
| Loans | — | `club_loans` + interest types |
| Owner UI | `finances.html` minimal | Full P&L + loans |

---

*Last updated: planning note for post–transfer/draft work. Link from `supabase/sql/README.md` when implementation starts.*
