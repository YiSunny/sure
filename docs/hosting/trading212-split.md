# Trading 212 Cash/Portfolio preview

This opt-in feature extends the Trading 212 connector; it does not require a
second API key. Existing connections remain combined until explicitly split.
Enable preview features in Settings → Preferences to see the split and CSV links
on the Trading 212 connection card.

## Accounting and data ownership

- Cash is a `Depository` account; Portfolio is an `Investment` account.
- Each pair shares the same upstream account ID, real owner and copied sharing
  permissions. Permission to view/annotate is not permission to split an account.
- Cash balance is `totalValue - investments.currentValue` from one summary.
  `availableToTrade` is **not** all cash: Spending Pot cash is omitted from it.
  Pie cash may be included in reported portfolio value; it is not added again.
- Both the summary and position-wallet values are retained/checked. Currency,
  completeness and impossible values fail validation rather than invent balances.
- The Cash sibling contains card purchases, refunds, interest, cashback,
  deposits/withdrawals, dividends and trade settlements. Portfolio contains trades,
  holdings, valuations and the paired settlement legs, not card purchases.
- Trade funding is **not inferred** from `AUTOINVEST`, `IOS` or `walletImpact`.
  These fields do not identify Main versus existing Pie funding. Unknown funding
  fails the pair atomically with a visible error. Independently reviewed funding
  can book only the Cash-funded portion and offset that portion in Portfolio;
  the remainder consumes/replenishes existing allocated Pie cash. Settlement legs
  are not living expenses. This safety guard is not automatic Pie reconciliation.
- Holdings retain native quotes/cost basis and a separate, dated provider wallet
  valuation. That value is used for balance materialization and allocation on the
  snapshot day; it is not carried back as an invented historical FX rate. Explicit
  Pie cash anchors the cash component; small summary/position quote discrepancies
  use non-cash balance reconciliation, never spendable cash or a balancing entry.
- Original provider source and reference remain attached to cash entries. Moving
  rows without changing routing would create duplicates; use the split operation.
- Connection mutations acquire the item lock before provider/statement locks,
  matching sync scheduling. Split-pair processing is atomic: a cash conflict rolls
  back the companion portfolio update rather than leaving mismatched totals.

## Before splitting an existing account

1. Take an encrypted off-server database/storage/configuration backup and test an
   isolated restore. Retain the encryption keys needed to decrypt restored data.
2. Obtain a fresh provider summary (less than 24 hours old) and compare it with the app's account value,
   Main Pot, Spending Pot, Pie cash and positions.
3. Rehearse in an isolated restore with no Sidekiq worker, no provider credentials
   sent to external tools, and no network access. Test only the intended owner.
4. Resolve/review legacy transfer matches and non-provider cash entries. The
   splitter refuses these conflicts instead of deleting them. Duplicated manual
   account experiments must be archived under a separately reviewed migration;
   merely disabling them can still affect historical reports.
   After splitting, `trading212:archive_preview` and explicitly confirmed
   `trading212:archive` can preserve a same-owner manual duplicate while disabling
   it and excluding it from reports. They require `PROVIDER_ACCOUNT_ID`,
   `LEGACY_ACCOUNT_ID`, `ACTOR_ID` and (apply only) `CONFIRM_ARCHIVE=yes`, and refuse
   unresolved transfers. They never delete entries or reject transfers themselves.
   For a verified real funding transfer, `Trading212Account::TransferReview`
   accepts an explicit transfer ID, old entry ID and exact CSV/provider reference
   and reattaches the existing relationship to Cash. It preserves status and bank
   counterpart, audits the change and rejects cross-owner or ambiguous targets.
5. Confirm the preview. Existing account/entry identities, categories, notes and
   sharing are retained where possible. Previous combined valuations and account
   values are captured in encrypted `split_audit_payload` before obsolete anchors
   are removed. Disabled accounts remain disabled; the operation does not trigger
   a provider sync or fabricate a zero opening balance.
6. Verify historical coverage and trade settlement, then activate both siblings
   together. A half-enabled pair fails processing instead of booking half a trade.

This migration is not automatically reversible through the UI. Test first and
retain the backup/audit snapshot; never roll back its schema migration after
creating split siblings without a reviewed data consolidation/restore.

## Original history CSV upload

Operators can inspect a stored snapshot without making a web request or starting
a sync with `PROVIDER_ACCOUNT_ID=... ACTOR_ID=... bin/rails trading212:split_preview`.
The separate `trading212:split` task requires `CONFIRM_SPLIT=yes`; it still refuses
conflicts and does not activate accounts. `trading212:statement_preview` accepts
the split Cash provider ID, actor ID and `CSV_PATH` and prints aggregate counts
only, without persisting a statement or exposing merchant details.

Use **Enrich Trading 212 cash from history CSV** on the selected connection's
Cash account. Upload the original export, inspect the preview, then apply it.

- No CSV trades/dividends are independently inserted. These remain API-owned.
- Cash rows match only the selected account's exact `ID`/API `reference`, amount,
  currency and supported action/type. Never match by amount and nearby date alone.
- Missing IDs, unknown actions, wrong-account references, conflicting amounts,
  protected edits and suspicious transfer links block the batch atomically.
- Posted API dates remain the ledger dates. CSV purchase timestamp, action,
  merchant category and file checksum remain in provenance.
- Card debit/credit become ordinary spending/refund activity. Positive cashback
  becomes a credit; negative cashback is a clawback outflow, not income.
- Actual funding deposits/withdrawals can be transfer candidates. Card payments,
  rewards, interest and unenriched generic cash events are not automatically
  paired to other accounts just because their amounts happen to match.
- Repeating the file or uploading an overlapping range does not create new cash
  entries. Rows present in raw API history but not yet processed are enriched on
  their next sync. New files cannot silently replace conflicting prior metadata.
- Before-values are recorded for existing entries. Batch reversal is allowed only
  when no later batch, user edit, transfer or newly synced entry makes it unsafe;
  otherwise it requires explicit review. The database backup is still required.

## History limits and reporting

Exports can start after the requested reporting year. Keep the actual earliest
available date (for example, March rather than January) as an explicit coverage
gap. Do not invent zero balances/transactions for unavailable months. A CSV's
first and last matched date do not prove every intervening event was exported.

API-only generic deposits/withdrawals are shown as unclassified cash movements,
with kind `unclassified` and `classification_pending` provider metadata. They
affect posted balances but are excluded from income/spending/statistical reports.
CSV-confirmed funding is excluded even before a bank counterpart is paired. A
dashboard/report warning remains until unknown cash and unmatched funding are
resolved: the other bank leg may still affect reports and is never silently hidden.
Protected legacy rows with pending metadata receive the same report treatment
without rewriting their edits. Reports for unenriched periods remain provisional.
Dividends and securities-lending interest booked once on Cash are also attributed
in investment-income totals, subject to both siblings' visibility/report settings.
Free-cash interest remains cash income, not portfolio yield. Household living expenses and investment allocations should
be reviewed separately; this feature does not change other providers' budget
semantics or automatically configure new bank connections.

Pagination with a remaining next page at the safety limit and unsupported split
cash types fail rather than committing incomplete history. Account pages show
successful ledger processing time separately from raw fetch time, unresolved trade
funding, unsupported activity and quote reconciliation. An established currency
mismatch requires manual denomination migration; no sync relabels that ledger.

### Explicit funding review

Only with independent records identifying the funding amount, use the operator
task `trading212:review_settlement` with `PROVIDER_ACCOUNT_ID` (Portfolio),
`ACTOR_ID`, exact `FILL_REFERENCE`, `CASH_AMOUNT`, `FUNDING_EVIDENCE` and
`CONFIRM_FUNDING_REVIEW=yes`. `CASH_AMOUNT` is the non-negative amount crossing
Cash/Portfolio for either a buy or sale: zero means entirely existing Pie cash;
the full wallet amount means entirely Cash-funded. A mixed amount must not exceed
the wallet amount. Review is recorded with actor/time and encrypted evidence; it
does not start synchronization or change entries. Rewriting reviewed/booked amounts
requires a separate migration review. Do not use initiator labels as evidence.

Existing preview settlements made under the previous all-Cash assumption are not
silently deleted, reversed or blessed. They remain unverified until individually
reconciled. **Do not deploy or enable the split for a Pie user solely because the
synthetic allocation tests pass.** Missing historical pot funding is still a
rollout blocker, not an invitation to invent a balancing transfer.

### Cashback allocations and referral awards

An explicitly confirmed positive cashback receipt can fund Pie cash before an
ETF purchase. `trading212:review_cashback` accepts the Cash `PROVIDER_ACCOUNT_ID`,
exact `CASHBACK_REFERENCE`, `ACTOR_ID`, `FUNDING_EVIDENCE` and
`CONFIRM_FUNDING_REVIEW=yes`. It records a review only, in encrypted audit data.
Processing retains the original cashback income once and creates a paired,
budget-excluded Cash→Portfolio allocation on its posted date. A subsequent
Pie-funded buy consumes Portfolio cash without another Main/Cash debit. Both
steps are needed to avoid inflated Cash history and double-counted reward income.
There is no default activation date, instrument or initiator rule for all users.
Earlier cashback is not allocated retrospectively; negative cashback reversals
are explicitly refused by this positive-credit review path. Missing Pie History
alone does not establish which pot paid a reversal.

For independently confirmed referral shares represented by the API as a BUY,
use `FUNDING_TYPE=referral_reward` and `CASH_AMOUNT=0` with the existing settlement
review task. Processing keeps the original native trade and records an offsetting
referral benefit inside Portfolio; it does not debit Main/Cash, create a dividend
or treat the awarded shares as personal contributions. A SYSTEM order is not, by
itself, proof of a referral. Unresolved fees or cash charges must not be inferred
from the award value. Existing synthetic settlement legs still require reviewed
migration before either zero-Cash funding path can process them.

Reviewed or booked funding cannot be silently rewritten. Protected/locked legs,
changed amounts, wrong owners, rejected/other transfers and conflicting statements
fail rather than deleting references. Statement reversal is blocked while its
cashback funding review remains in place. Tests use fabricated identifiers; keep
owner confirmations and real export references outside public source files.

## Verification

Run the normal full pre-PR checks from `docs/llm-guides/development.md`.
Focused coverage:

```sh
bin/rails test test/models/trading212_split_test.rb \
  test/models/trading212_statement_test.rb \
  test/models/trading212_settlement_test.rb \
  test/models/trading212_split_migration_test.rb \
  test/models/trading212_legacy_archive_test.rb \
  test/controllers/trading212_workflows_test.rb \
  test/models/family/auto_transfer_matchable_test.rb
```

In the isolated real-data rehearsal, check: no provider cash rows in Portfolio;
one Cash entry per provider reference; exact owner/sharing preservation; cash plus
portfolio equals provider total; identical and overlapping uploads create no
duplicates; repeated provider processing preserves enrichment; foreign settlement
offsets use the trade's rate; historical charts do not retain duplicate accounts;
and other owners' data is unchanged. Real statements must not be committed as
fixtures or included in logs/screenshots for a public PR.

### Test environment parity

The upstream full behavioral suite expects `SELF_HOSTED=false` for managed-only
subscription/AI/rate-limit cases. Keep the operator's production settings separate
from this test environment. Supply `PGUSER` as well as `POSTGRES_USER` when testing
with a non-OS PostgreSQL role: the upstream recurring-pipeline lock test opens a
raw PG connection and otherwise defaults to the process user's OS role.

Run the browser workflow alone with:

```sh
DISABLE_PARALLELIZATION=true bin/rails test test/system/trading212_workflow_test.rb
```

The `test:system` task in this release collects all system tests even when given a
file argument. Do not start it against a database already used by another suite.
Full behavioral/baseline comparisons should use separate source snapshots,
databases and Redis namespaces, with persistent log files outside the process's
terminal stream so an SSH interruption cannot lose the final result.

## Bounded self-hosted build

For a deployment pinned to 0.7.5, `Dockerfile.trading212` overlays only application,
configuration and schema files on the same release image. It intentionally does
not copy `.env`, private reports, backups or test data. Existing compiled assets
are reused because this preview adds no JavaScript/CSS dependencies.

```sh
docker build --network none -f Dockerfile.trading212 \
  -t sure-trading212:preview .
```

Override the entrypoint for isolated checks. The original image's server
entrypoint can prepare the database automatically; do not let an unreviewed
container start migrate production. This image alone does not split, enable,
delete or archive any financial account.

An optional disposable Chromium runner is provided in `Dockerfile.trading212-test`.
It installs browser packages into a test image, not the production host/app. Mount
a separate source checkout and use a separate fixture database/Redis namespace;
never point this runner at the restored private-data database or production.
