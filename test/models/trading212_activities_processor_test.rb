require "test_helper"

class Trading212ActivitiesProcessorTest < ActiveSupport::TestCase
  fixtures :families, :trading212_items, :trading212_accounts, :accounts, :securities
  setup do
    @family = families(:dylan_family)
    @trading212_item = trading212_items(:configured_item)
    @trading212_account = trading212_accounts(:main_account)

    # Link to an investment account
    @account = @family.accounts.create!(
      name: "Test T212 Investment",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    @trading212_account.ensure_account_provider!(@account)
    @trading212_account.reload
  end

  # === process orders (BUY) ===

  test "processes a filled buy order as a Buy trade" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_001",
            "status" => "FILLED",
            "side" => "BUY",
            "instrument" => {
              "ticker" => "AAPL_US_EQ",
              "isin" => "US0378331005",
              "name" => "Apple Inc."
            },
            "filledValue" => "1750.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_001",
            "quantity" => "10",
            "price" => "175.00",
            "filledAt" => "2024-06-15T10:30:00Z"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:trades]
    entry = @account.entries.find_by(external_id: "trading212_order_fill_001")
    assert_not_nil entry
    assert_equal "Trade", entry.entryable_type
    assert_equal "Buy", entry.entryable.investment_activity_label
    assert entry.entryable.qty.positive?
  end

  test "processes a filled sell order as a Sell trade" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_002",
            "status" => "FILLED",
            "side" => "SELL",
            "instrument" => {
              "ticker" => "TSLA_US_EQ",
              "name" => "Tesla Inc."
            },
            "filledValue" => "2500.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_002",
            "quantity" => "10",
            "price" => "250.00",
            "filledAt" => "2024-06-15T10:30:00Z"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:trades]
    entry = @account.entries.find_by(external_id: "trading212_order_fill_002")
    assert_equal "Sell", entry.entryable.investment_activity_label
    assert entry.entryable.qty.negative?
  end

  test "skips non-filled orders" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_003",
            "status" => "PENDING",
            "side" => "BUY",
            "instrument" => { "ticker" => "MSFT_US_EQ", "name" => "Microsoft" },
            "filledValue" => "400.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_003",
            "quantity" => "1",
            "price" => "400.00"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:trades]
  end

  test "uses order id as external_id when fill id is absent" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_005",
            "status" => "FILLED",
            "side" => "BUY",
            "instrument" => { "ticker" => "MSFT_US_EQ", "name" => "Microsoft" },
            "filledValue" => "400.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "quantity" => "1",
            "price" => "400.00",
            "filledAt" => "2024-06-15T10:30:00Z"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:trades]
    entry = @account.entries.find_by(external_id: "trading212_order_order_005")
    assert_not_nil entry
  end

  # === process dividends ===

  test "processes dividend as a cash transaction" do
    @trading212_account.update!(
      raw_dividends_payload: [
        {
          "reference" => "div_001",
          "ticker" => "AAPL_US_EQ",
          "amount" => "25.00",
          "paidOn" => "2024-06-15",
          "quantity" => "50",
          "grossAmountPerShare" => "0.50",
          "type" => "ORDINARY"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:dividends]
    entry = @account.entries.find_by(external_id: "trading212_dividend_div_001")
    assert_not_nil entry
    assert_equal "Transaction", entry.entryable_type
    assert_equal "Dividend", entry.entryable.investment_activity_label
    # Dividends are negative in Sure (inflow)
    assert entry.amount.negative?
  end

  test "skips dividend with blank reference" do
    @trading212_account.update!(
      raw_dividends_payload: [
        {
          "ticker" => "AAPL_US_EQ",
          "amount" => "25.00",
          "paidOn" => "2024-06-15"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:dividends]
  end

  test "skips dividend with zero or nil amount" do
    @trading212_account.update!(
      raw_dividends_payload: [
        { "reference" => "div_zero", "amount" => "0", "paidOn" => "2024-06-15" },
        { "reference" => "div_nil", "amount" => nil, "paidOn" => "2024-06-15" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:dividends]
  end

  # === process cash transactions ===

  test "processes DEPOSIT as a funds movement, not an investment contribution" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_001",
          "type" => "DEPOSIT",
          "amount" => "1000.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_001")
    assert_not_nil entry
    assert_equal "funds_movement", entry.entryable.kind
    assert_nil entry.entryable.investment_activity_label
    assert_nil entry.entryable.category_id
    # Deposits are negative in Sure (inflow)
    assert entry.amount.negative?
  end

  test "a deposit is neither income nor spending, and buying an ETF with it is not spending either" do
    @family.update!(currency: "USD")
    @trading212_account.update!(
      raw_transactions_payload: [
        { "reference" => "top_up", "type" => "DEPOSIT", "amount" => "1000.00", "dateTime" => "2024-06-15T10:00:00Z" }
      ],
      raw_orders_payload: [
        {
          "order" => { "id" => "etf_buy", "status" => "FILLED", "side" => "BUY",
                       "instrument" => { "ticker" => "VWCE_EQ", "name" => "ETF" }, "filledValue" => "1000.00" },
          "fill" => { "id" => "etf_fill", "quantity" => "10", "price" => "100.00", "filledAt" => "2024-06-16T10:00:00Z" }
        }
      ]
    )

    Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    totals = IncomeStatement.new(@family, accounts: @family.accounts.where(id: @account.id))
      .totals(date_range: Date.new(2024, 6, 1)..Date.new(2024, 6, 30))
    assert_equal Money.new(0, "USD"), totals.income_money
    assert_equal Money.new(0, "USD"), totals.expense_money
  end

  test "a bank top-up matched to its Trading 212 deposit is not counted as spending" do
    @family.update!(currency: "USD")
    bank = accounts(:depository)
    bank_leg = bank.entries.create!(name: "To Trading 212", amount: 1000, currency: "USD", date: Date.new(2024, 6, 14),
      entryable: Transaction.new)
    @trading212_account.update!(raw_transactions_payload: [
      { "reference" => "top_up", "type" => "DEPOSIT", "amount" => "1000.00", "dateTime" => "2024-06-15T10:00:00Z" }
    ])

    Trading212Account::ActivitiesProcessor.new(@trading212_account).process
    @family.auto_match_transfers!

    deposit = @account.entries.find_by!(external_id: "trading212_transaction_top_up").transaction
    assert_equal bank_leg.transaction, deposit.reload.transfer&.outflow_transaction
    assert_equal "funds_movement", bank_leg.transaction.reload.kind
    assert_nil bank_leg.transaction.category_id

    totals = IncomeStatement.new(@family, accounts: @family.accounts.where(id: [ bank.id, @account.id ]))
      .totals(transactions_scope: Transaction.where(id: [ bank_leg.entryable_id, deposit.id ]),
        date_range: Date.new(2024, 6, 14)..Date.new(2024, 6, 15))
    assert_equal Money.new(0, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "resync resets a deposit and its matched bank leg that earlier syncs stored as investment contributions" do
    category = ensure_investment_contributions_category(@family)
    bank = accounts(:depository)
    legacy = Account::ProviderImportAdapter.new(@account).import_transaction(
      external_id: "trading212_transaction_legacy", amount: -500, currency: "USD", date: Date.new(2024, 6, 15),
      name: "Contribution", source: "trading212", investment_activity_label: "Contribution"
    ).transaction
    assert_equal "investment_contribution", legacy.kind
    bank_leg = bank.entries.create!(name: "To Trading 212", amount: 500, currency: "USD", date: Date.new(2024, 6, 15),
      entryable: Transaction.new(kind: "investment_contribution", category: category)).transaction
    Transfer.create!(inflow_transaction: legacy, outflow_transaction: bank_leg, status: "confirmed")

    @trading212_account.update!(raw_transactions_payload: [
      { "reference" => "legacy", "type" => "DEPOSIT", "amount" => "500.00", "dateTime" => "2024-06-15T10:00:00Z" }
    ])
    2.times { Trading212Account::ActivitiesProcessor.new(@trading212_account).process }

    legacy.reload
    assert_equal "funds_movement", legacy.kind
    assert_nil legacy.investment_activity_label
    assert_nil legacy.category_id
    bank_leg.reload
    assert_equal "funds_movement", bank_leg.kind
    assert_nil bank_leg.category_id
    assert legacy.transfer.present?, "The matched transfer is kept"
  end

  test "resync keeps classifications the user edited or a Rule assigned on a legacy deposit" do
    category = ensure_investment_contributions_category(@family)
    edited = Account::ProviderImportAdapter.new(@account).import_transaction(
      external_id: "trading212_transaction_edited", amount: -500, currency: "USD", date: Date.new(2024, 6, 15),
      name: "Contribution", source: "trading212", investment_activity_label: "Contribution"
    )
    edited.update!(user_modified: true)
    ruled = Account::ProviderImportAdapter.new(@account).import_transaction(
      external_id: "trading212_transaction_ruled", amount: -300, currency: "USD", date: Date.new(2024, 6, 15),
      name: "Contribution", source: "trading212", kind: "standard"
    ).transaction
    assert ruled.enrich_attribute(:category_id, category.id, source: "rule")

    @trading212_account.update!(raw_transactions_payload: [
      { "reference" => "edited", "type" => "DEPOSIT", "amount" => "500.00", "dateTime" => "2024-06-15T10:00:00Z" },
      { "reference" => "ruled", "type" => "DEPOSIT", "amount" => "300.00", "dateTime" => "2024-06-15T10:00:00Z" }
    ])
    Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    assert_equal "investment_contribution", edited.transaction.reload.kind
    assert_equal "Contribution", edited.transaction.investment_activity_label
    assert_equal category.id, ruled.reload.category_id
  end

  test "processes WITHDRAW as Withdrawal" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_002",
          "type" => "WITHDRAW",
          "amount" => "500.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_002")
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
    assert entry.amount.positive?
  end

  test "processes INTEREST as Interest" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_003",
          "type" => "INTEREST",
          "amount" => "5.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_003")
    assert_equal "Interest", entry.entryable.investment_activity_label
  end

  test "processes INTEREST_ON_FREE_CASH as Interest" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_003_free_cash",
          "type" => "INTEREST_ON_FREE_CASH",
          "amount" => "0.03",
          "currency" => "EUR",
          "dateTime" => "2026-09-09T01:13:26.766Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_003_free_cash")
    assert_not_nil entry
    assert_equal "Interest", entry.entryable.investment_activity_label
    assert entry.amount.negative?
  end

  test "processes FEE as Fee" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_004",
          "type" => "FEE",
          "amount" => "2.50",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_004")
    assert_equal "Fee", entry.entryable.investment_activity_label
  end

  test "skips transaction with blank reference" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "type" => "DEPOSIT",
          "amount" => "100.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:transactions]
  end

  test "skips transaction with zero amount" do
    @trading212_account.update!(
      raw_transactions_payload: [
        { "reference" => "txn_zero", "type" => "DEPOSIT", "amount" => "0", "dateTime" => "2024-06-15T10:00:00Z" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:transactions]
  end

  # === idempotency ===

  test "processor is idempotent - does not duplicate entries" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_idempotent",
            "status" => "FILLED",
            "side" => "BUY",
            "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" },
            "filledValue" => "1750.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_idempotent",
            "quantity" => "10",
            "price" => "175.00"
          }
        }
      ],
      raw_dividends_payload: [
        { "reference" => "div_idempotent", "amount" => "10.00", "paidOn" => "2024-06-15" }
      ],
      raw_transactions_payload: [
        { "reference" => "txn_idempotent", "type" => "DEPOSIT", "amount" => "100.00", "dateTime" => "2024-06-15T10:00:00Z" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    first_result = processor.process
    second_result = processor.process

    assert_equal first_result, second_result
    assert_equal 1, @account.entries.where(external_id: "trading212_order_fill_idempotent").count
    assert_equal 1, @account.entries.where(external_id: "trading212_dividend_div_idempotent").count
    assert_equal 1, @account.entries.where(external_id: "trading212_transaction_txn_idempotent").count
  end

  # === process returns early without account ===

  test "returns zero counts when no account linked" do
    @trading212_account.account_provider.destroy!

    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => { "id" => "o1", "status" => "FILLED", "side" => "BUY",
                       "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" } },
          "fill" => { "quantity" => "10", "price" => "175.00" }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal({ trades: 0, dividends: 0, transactions: 0 }, result)
  end

  # === combined results ===

  test "returns combined stats for all activity types" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => { "id" => "o1", "status" => "FILLED", "side" => "BUY",
                       "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" } },
          "fill" => { "id" => "f1", "quantity" => "10", "price" => "175.00", "filledAt" => "2024-06-15T10:30:00Z" }
        },
        {
          "order" => { "id" => "o2", "status" => "FILLED", "side" => "SELL",
                       "instrument" => { "ticker" => "TSLA_US_EQ", "name" => "Tesla" } },
          "fill" => { "id" => "f2", "quantity" => "5", "price" => "250.00", "filledAt" => "2024-06-15T11:00:00Z" }
        }
      ],
      raw_dividends_payload: [
        { "reference" => "d1", "amount" => "10.00", "paidOn" => "2024-06-15" }
      ],
      raw_transactions_payload: [
        { "reference" => "t1", "type" => "DEPOSIT", "amount" => "1000.00", "dateTime" => "2024-06-15T10:00:00Z" },
        { "reference" => "t2", "type" => "FEE", "amount" => "2.00", "dateTime" => "2024-06-15T10:00:00Z" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 2, result[:trades]
    assert_equal 1, result[:dividends]
    assert_equal 2, result[:transactions]
  end
end
