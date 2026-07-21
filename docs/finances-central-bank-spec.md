# GPSL finances — line items & central bank (design memory)

**Status:** Model A **signed off** (Jun 2026). SQL patch [`supabase/sql/patches/central_bank_model_a_flows.sql`](../supabase/sql/patches/central_bank_model_a_flows.sql) routes league flows through `post_club_ledger(..., p_bank_leg := true)`. Gate receipts stay outside the bank (“fans”). Club↔club transfer fees stay direct.

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

**UI:** `finances.html` → **Sales** and **Purchases** totals only. **No future / delayed fees** (exploitable; not used).

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `transfer_sale` | **Sales** — player sale | Credit | Transfer list, direct offer sold, etc. |
| `transfer_foreign_sale` | **Sales** — foreign sale | Credit | Overflow foreign slot |
| `transfer_overflow_release` | **Sales** — squad release (MV) | Credit | Overflow / release credit |
| `transfer_purchase` | **Purchases** — player bought | Debit | Draft auction, market, special auctions |
| `transfer_agent_fee` | **Purchases** — agent fee | Debit | Rolled into purchase total in UI |

~~`transfer_future_fee`~~ — **not used**.

### 1.3 Prize money & TV

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `prize_league` | League prize money | Credit | Admin + league table by position; **paid after all 38 league matches** |
| `prize_cup` | Cup prize money | Credit | **Per tie** after result; per-round amounts in admin |
| `prize_challenge` | Challenge prize money | Credit | Start / mid / end targets; maybe ₿1M per task + first-to-complete bonus |
| `tv_revenue` | TV revenue | Credit | Random big matches; top weighted > mid > bottom (~₿1M/match historically) |
| `prize` | Prize (generic, interim) | Credit | **Live** until split into types above |
| `gate_league_home` | Gate — league home | Credit | See §1.4 (also infrastructure UI) |
| `gate_cup_share` | Gate — cup 50% | Credit | See §1.4 |

### 1.4 Infrastructure (stadium & facilities)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `gate_league_home` / `gate_cup_share` | **Gate receipts** | Credit | League: home 100%, away 0%. Cup: 50/50. Per match **capacity × ₿20**; cumulative as results confirm |
| `infra_maintenance` | **Stadium maintenance** | Debit | **12.5%** of stadium value; value = **capacity × ₿1,500** |
| `infra_purchase` | **Infrastructure purchases** | Debit | Starting-budget premium for clubs with larger starting stadiums |
| `infra_expansion` | **Expansions** | Debit | Capacity upgrade cost — formula TBD |
| `gov_fine_compensation` | **Fines & compensation** | Debit/credit | DOGSO, time wasting, etc. — tariff list TBD |

### 1.5 Government / league (subsidies & tax)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `gov_hg_subsidy` | **HG subsidy** | Credit | Tiered homegrown levels (e.g. flying the flag) — rules TBD |
| `gov_youth_subsidy` | **Youth subsidy** | Credit | Scales with youth players in squad |
| `gov_bnb_subsidy` | **Built not bought** | Credit | ~₿10M for weaker squads — formula TBD |
| `gov_emergency_tax` | **Emergency tax** | Debit | **Admin** — knock down excess cash |
| `gov_income_tax` | **Income tax** | Debit | **% of player spend** — rate in admin |

### 1.6 Player upkeep (wages & contract costs)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `wage_squad` | **Wages** | Debit | Admin **% of squad value**; per-player wage from calculated value or negotiated (free-agent path) |
| `wage_renewal_34plus` | **34+ renewals** | Debit | Per player 34+ each season |
| `wage_star_tax` | **Star tax** | Debit | Players **70+** — formula TBD |

### 1.7 Staff & contracts (non-wage)

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `staff_manager_salary` | **Manager salary** | Debit | Rating → value → % salary |
| `contract_signing_offer` | **Contract offers** | Debit | Manager renewal fee every **2 seasons** |
| `contract_release_comp` / `_received` | **Contract releases** | Debit/credit | Failed objectives / resign / sack; fee may return; manager cannot rejoin same club |
| `contract_termination` | **Contract termination** | Debit/credit | Mid-season or EOS firing |

### 1.8 End of season

| Code | Description | Direction | Notes |
|------|-------------|-----------|--------|
| `eos_debt_interest` | **Debt interest** | Debit | On **negative** balances at EOS (and loans when live) |
| `eos_balance_interest` | **Balance interest** | Credit | **0.5%** on **positive** balances at EOS — paid from central bank |
| `eos_ffp_charge` | **FFP charges** | Debit | Flat **₿50M** if balance **≤ −₿100M** at Close Finances (after wages/maintenance/debt interest); then highest-MV players released @ MV until balance **> −₿99,999,999**; those players cannot rejoin that club next season; club gets a **one-window buy embargo** (next window; skips current if already open) |
| `eos_injection` | **End of season injection** | Credit | Individual or mass; same family as emergency tax — **admin** |

### 1.9 Balance summary (UI only, not ledger types)

| Field | Description |
|-------|-------------|
| `balance_opening` | Season opening balance (stored at rollover — UI placeholder “Soon”) |
| `balance_current` | **Current balance** — opening + all posted income/costs (`Club_Finances.balance`) |
| `balance_predicted_eos` | **Predicted EOS balance** — forecast gates, prizes, wages, subsidies, tax, etc. (UI placeholder “Soon”) |

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

Default recommendation: **Model A** — **signed off.**

### 2.5 Signed-off counterparty rules (Model A)

| Flow | Counterparty | Ledger | Central bank leg |
|------|--------------|--------|------------------|
| GPDB draft signings — **player**, **manager**, **club** auction | GPSL Central Bank | `transfer_purchase` / `infra_purchase` | Yes — fee paid **to** the bank |
| Government subsidies (HG, youth, BnB) | Central bank | `gov_*_subsidy` | Yes — paid **from** the bank |
| Taxes (emergency, income, **star tax**) | Central bank | `gov_emergency_tax`, `gov_income_tax`, `wage_star_tax` | Yes — collected **to** the bank |
| Loan interest | Central bank | `loan_interest_payment` | Yes (already wired) |
| **EOS balance interest** — **0.5%** on positive balances | Central bank | `eos_balance_interest` | Yes — paid **from** the bank at end of season |
| GPSL monthly TV money | Central bank | `tv_revenue` | Yes |
| League / cup / challenge prize money | Central bank | `prize_league`, `prize_cup`, `prize_challenge` | Yes |
| Stadium purchase (club assignment / club auction) | Central bank | `infra_purchase` | Yes — **backfill** historical rows |
| Stadium expansion (order, penalty, refund) | Central bank | `infra_expansion`, `infra_expansion_penalty`, `infra_expansion_refund` | Yes |
| Fines | Central bank | `gov_fine_compensation` (debit) | Yes — clubs **to** the bank |
| Compensation | Central bank | `gov_fine_compensation` (credit) | Yes — bank **to** clubs |
| FFP charges | Central bank | `eos_ffp_charge` | Yes |
| **Gate receipts** | Virtual **“fans”** (not a GPSL entity) | `gate_league_home`, `gate_cup_share` | **No** — outside income from match attendance |
| Player wages, manager wages | Virtual **“players”** / staff | `wage_squad`, `staff_manager_salary` | **No** — club outgoings only |
| 34+ renewal fees | Virtual **“players”** | `wage_renewal_34plus` | **No** |
| Player / manager **transfer fees** (club market) | **Club ↔ club** | `transfer_sale`, `transfer_purchase` | **No** — buyer debited, seller credited directly |

**Virtual counter-parties** (fans, players, managers) are not recorded in `gpsl_bank_account` or `bank_ledger`. They exist only as the semantic destination of club ledger descriptions.

**Admin after deploy:**

```sql
-- Preview bank reserve adjustment from historical club ledger rows
SELECT public.backfill_central_bank_legs(true);

-- Apply mirror rows (no club balance change)
SELECT public.backfill_central_bank_legs(false);

-- End of season: 0.5% credit on positive balances
SELECT public.competition_post_eos_balance_interest(<season_id>);
```

### 2.6 Functions to centralise (migrate over time)

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
- **End of season:** `eos_balance_interest` — **0.5% credit** on positive club balances (central bank pays out).
- Posting runs in **season rollover** job (same window as contract tick / wage bill).

### 3.4 UI (live)

- `finances.html` — **Take a loan** / **Repay** (RPC `club_take_loan`, `club_repay_loan`); active loans table; headroom from `gpsl_bank_public`.
- Defaults: min ₿1M draw, max ₿50M per draw, ₿100M outstanding per club, rate from `policy_interest_rate_pct`.
- **EOS interest** on outstanding principal — not automated yet.
- Admin: set `loans_enabled`, limits, and rate on `gpsl_bank_account` (SQL for now).

---

## 4. UI split

**Club finances** — `finances.html` + `finance_ui.js`: balance, season accounts (Excel structure), club activity ledger. Link to bank only.

**GPSL Central Bank** — `central_bank.html` + `central_bank.css` + `central_bank.js` + `bank_counter.js`:

1. **Hero** — SVG branch building, treasury stats.
2. **Treasury** — reserves, bank income/expenditure from `bank_ledger_public`, full bank ledger.
3. **League loans** — all clubs via `club_loans_league_public`.
4. **Service counter** — take loan / repay (`club_take_loan`, `club_repay_loan`).
5. Dashboard tile + nav **Central Bank**.

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
| Gates | `competition_finance_ledger`, **no bank leg** (fans) | Unchanged |
| GPDB drafts / subsidies / prizes / TV / fines | `post_club_ledger` + bank leg | Deploy `central_bank_model_a_flows.sql` |
| Club↔club transfers | Direct balance, ledger only | Unchanged (no bank leg) |
| Wages / 34+ | Club ledger debits, **no bank leg** | Virtual payees |
| Loans | `club_take_loan` / `club_repay_loan` + bank leg | EOS debt interest job |
| EOS balance interest | `competition_post_eos_balance_interest` | Wire into season rollover |
| Owner UI | `finances.html` minimal | Full P&L + loans |

---

*Last updated: Model A counterparty rules signed off; see `central_bank_model_a_flows.sql`.*
