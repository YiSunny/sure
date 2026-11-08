require "test_helper"

class Trading212SettlementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @portfolio = trading212_accounts(:main_account)
    @portfolio.trading212_item.update!(family: @user.family)
    @portfolio.update!(kind: "portfolio", currency: "EUR", raw_orders_payload: [ order ],
      settlement_allocations: { "fill" => { "cash_amount" => "100", "wallet_amount" => "100", "currency" => "EUR", "evidence" => "Synthetic bank-funded test" } })
    @account = @user.family.accounts.create!(name: "Portfolio", currency: "EUR", balance: 1000, cash_balance: 0,
      owner: @user, accountable: Investment.new(subtype: "brokerage"))
    @portfolio.ensure_account_provider!(@account)
    @cash_provider = @portfolio.trading212_item.trading212_accounts.create!(kind: "cash", currency: "EUR",
      trading212_account_id: @portfolio.trading212_account_id)
    @cash = @user.family.accounts.create!(name: "Cash", currency: "EUR", balance: 1000,
      owner: @user, accountable: Depository.new)
    @cash_provider.ensure_account_provider!(@cash)
  end

  test "buy and repeated sync book cash once and neutralize portfolio trade cash" do
    processor = Trading212Account::ActivitiesProcessor.new(@portfolio)
    processor.process
    assert_equal 1, @account.entries.trades.count
    assert_equal 1, @account.entries.transactions.count
    assert_equal 1, @cash.entries.transactions.count
    assert_equal 0.to_d, @account.entries.sum(:amount)
    assert_equal 100.to_d, @cash.entries.sum(:amount)
    assert_equal "funds_movement", @cash.entries.transactions.first.transaction.kind
    assert_equal "confirmed", @cash.entries.transactions.first.transaction.transfer.status
    assert_no_difference "Entry.count" do
      processor.process
      Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    end
  end

  test "AutoInvest does not imply either Cash or Pie funding" do
    data = order
    data["order"]["initiatedFrom"] = "AUTOINVEST"
    @portfolio.update!(raw_orders_payload: [ data ], settlement_allocations: {})
    assert_no_difference "Entry.count" do
      assert_raises(Trading212Account::Snapshot::Invalid) do
        @portfolio.with_lock { Trading212Account::ActivitiesProcessor.new(@portfolio).process }
      end
    end
    assert_equal 1, @portfolio.reload.accounting_diagnostics[:unresolved_settlements]
  end

  test "funding review requires exact evidence and authorized same owner accounts and never starts sync" do
    @portfolio.update!(settlement_allocations: {})
    settlement = Trading212Account::Settlement.new(@portfolio)
    assert_raises(ArgumentError) { settlement.review!(reference: "fill", cash_amount: 40, evidence: "", actor: @user) }
    assert_raises(ActiveRecord::RecordNotFound) { settlement.review!(reference: "fill", cash_amount: 40, evidence: "Checked", actor: users(:family_member)) }
    @portfolio.trading212_item.expects(:sync_later).never
    assert_no_difference "Entry.count" do
      result = settlement.review!(reference: "fill", cash_amount: 40, evidence: "Synthetic statement confirms mixed funding", actor: @user)
      assert_equal "40.0", result["cash_amount"]
      assert_equal @user.id, result["actor_id"]
    end
    assert_raises(Trading212Account::Snapshot::Invalid) { settlement.review!(reference: "fill", cash_amount: 100, evidence: "Changed", actor: @user) }
  end

  test "reviewed Pie funded trade consumes existing portfolio cash without touching Cash" do
    @portfolio.update!(settlement_allocations: { "fill" => { "cash_amount" => "0", "wallet_amount" => "100", "currency" => "EUR", "evidence" => "Synthetic existing Pie cash" } })
    2.times { Trading212Account::ActivitiesProcessor.new(@portfolio).process }
    assert_equal 1, @account.entries.trades.count
    assert_equal 100.to_d, @account.entries.sum(:amount)
    assert_empty @cash.entries
    assert_empty @account.entries.transactions
  end

  test "reviewed mixed funding transfers only the Cash funded portion" do
    @portfolio.update!(settlement_allocations: { "fill" => { "cash_amount" => "40", "wallet_amount" => "100", "currency" => "EUR", "evidence" => "Synthetic mixed funding" } })
    2.times { Trading212Account::ActivitiesProcessor.new(@portfolio).process }
    assert_equal 40.to_d, @cash.entries.sole.amount
    assert_equal 60.to_d, @account.entries.sum(:amount)
    assert @cash.entries.sole.transaction.transfer.confirmed?
  end

  test "reviewed Pie sale replenishes portfolio cash without crediting Cash" do
    sell = order
    sell["order"]["side"] = "SELL"
    @portfolio.update!(raw_orders_payload: [ sell ], settlement_allocations: { "fill" => { "cash_amount" => "0", "wallet_amount" => "100", "currency" => "EUR", "evidence" => "Synthetic Pie reinvestment" } })
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    assert_equal(-100.to_d, @account.entries.trades.sole.amount)
    assert_empty @cash.entries
  end

  test "funding allocation exceeding the wallet fails without settlements" do
    @portfolio.update!(settlement_allocations: { "fill" => { "cash_amount" => "101", "wallet_amount" => "100", "currency" => "EUR", "evidence" => "Invalid test amount" } })
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::ActivitiesProcessor.new(@portfolio).process }
    assert_empty @cash.entries
    assert_empty @account.entries.transactions
  end

  test "changed reviewed allocation cannot silently rewrite existing settlements" do
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    @portfolio.update!(settlement_allocations: { "fill" => { "cash_amount" => "40", "wallet_amount" => "100", "currency" => "EUR", "evidence" => "Changed" } })
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::ActivitiesProcessor.new(@portfolio).process }
    assert_equal 100.to_d, @cash.entries.sole.amount
  end

  test "provider wallet valuation does not become FX phantom cash and preserves the native quote" do
    summary = { "currency" => "EUR", "totalValue" => 90510,
      "cash" => { "availableToTrade" => 10, "inPies" => 0, "reservedForOrders" => 0 },
      "investments" => { "currentValue" => 90500 } }
    foreign_position = position.deep_merge("instrument" => { "currency" => "USD" }, "quantity" => 1000, "currentPrice" => 100,
      "walletImpact" => { "currentValue" => 90500 })
    ExchangeRate.find_or_initialize_by(from_currency: "USD", to_currency: "EUR", date: Date.current).update!(rate: "0.9")
    @portfolio.update!(raw_summary_payload: summary, raw_positions_payload: [ foreign_position ], raw_orders_payload: [])
    Trading212Account::Processor.new(@portfolio).process
    holding = @account.holdings.sole
    assert_equal "USD", holding.currency
    assert_equal 100.to_d, holding.price
    assert_equal 100000.to_d, holding.amount
    assert_equal 90500.to_d, Balance::SyncCache.new(@account.reload).get_holdings_value(Date.current)
    current = Balance::ReverseCalculator.new(@account).calculate.find { |b| b.date == Date.current }
    assert_equal 0.to_d, current.cash_balance
    assert_equal 90500.to_d, current.balance
  end

  test "small quote residual remains outside explicit Pie cash" do
    @portfolio.update!(raw_orders_payload: [], raw_summary_payload: { "currency" => "EUR", "totalValue" => "1010.48",
      "cash" => { "availableToTrade" => 10, "inPies" => "0.48", "reservedForOrders" => 0 },
      "investments" => { "currentValue" => "1000.48" } }, raw_positions_payload: [ position.deep_merge("walletImpact" => { "currentValue" => "1000.01" }) ])
    Trading212Account::Processor.new(@portfolio).process
    current = Balance::ReverseCalculator.new(@account.reload).calculate.find { |b| b.date == Date.current }
    assert_equal "0.48".to_d, current.cash_balance
    assert_equal "-0.01".to_d, current.non_cash_adjustments
    attrs = current.to_h.except(:account)
    persisted = @account.balances.create!(attrs)
    assert_equal "1000.48".to_d, persisted.reload.end_balance
    assert_equal "0.48".to_d, persisted.end_cash_balance
    # Importing a newer raw summary is not a successfully processed ledger.
    # A later failure must not contaminate the previously accepted anchor.
    @portfolio.update!(raw_summary_payload: @portfolio.raw_summary_payload.deep_merge("cash" => { "inPies" => "99" }))
    current = Balance::ReverseCalculator.new(@account.reload).calculate.find { |b| b.date == Date.current }
    assert_equal "0.48".to_d, current.cash_balance
    assert_equal "-0.01".to_d, current.non_cash_adjustments
  end

  test "cash dividends keep security metadata without entering portfolio activity" do
    @portfolio.update!(raw_orders_payload: [], raw_dividends_payload: [
      { "reference" => "dividend", "ticker" => "TEST_EQ", "amount" => "0.25", "paidOn" => "2026-06-01", "quantity" => 1 }
    ])
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    assert_equal 0, @account.entries.transactions.count
    entry = @cash.entries.find_by!(external_id: "trading212_dividend_dividend")
    assert_equal "Dividend", entry.transaction.investment_activity_label
    assert entry.transaction.extra["security_id"].present?
    assert_equal(-"0.25".to_d, entry.amount)
  end

  test "investment income attribution includes dividends and lending but not free cash interest or cashback" do
    @portfolio.update!(raw_orders_payload: [], raw_dividends_payload: [ { "reference" => "div", "ticker" => "TEST_EQ", "amount" => 25, "paidOn" => Date.current.iso8601 } ],
      raw_transactions_payload: [
        { "reference" => "lending", "type" => "LENDING_INTEREST", "amount" => 2, "dateTime" => Time.current.iso8601 },
        { "reference" => "cash-interest", "type" => "INTEREST_ON_FREE_CASH", "amount" => 3, "dateTime" => Time.current.iso8601 }
      ])
    @user.family.update!(currency: "EUR")
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    before = @cash.entries.count
    totals = InvestmentStatement.new(@user.family, user: @user).totals
    assert_equal Money.new(25, "EUR"), totals.dividends
    assert_equal Money.new(2, "EUR"), totals.interest
    assert_equal before, @cash.entries.count
    assert_empty @account.entries
    @cash.update!(exclude_from_reports: true)
    assert_equal Money.new(0, "EUR"), InvestmentStatement.new(@user.family, user: @user).totals.dividends
    @cash.update!(exclude_from_reports: false)
    @account.update!(exclude_from_reports: true)
    assert_equal Money.new(0, "EUR"), InvestmentStatement.new(@user.family, user: @user).totals.dividends
  end

  test "negative dividend reversal reduces investment income without another ledger entry" do
    @user.family.update!(currency: "EUR")
    @portfolio.update!(raw_orders_payload: [], raw_dividends_payload: [
      { "reference" => "dividend", "amount" => 25, "paidOn" => Date.current.iso8601 },
      { "reference" => "reversal", "amount" => -5, "paidOn" => Date.current.iso8601 }
    ])
    2.times { Trading212Account::ActivitiesProcessor.new(@cash_provider).process }
    assert_equal 2, @cash.entries.count
    assert_equal 5.to_d, @cash.entries.find_by!(external_id: "trading212_dividend_reversal").amount
    assert_equal Money.new(20, "EUR"), InvestmentStatement.new(@user.family, user: @user).totals.dividends
  end

  test "unsupported cash activity fails the split pair and retains its last successful timestamp" do
    previous = 2.days.ago.change(usec: 0)
    @portfolio.update!(last_processed_at: previous, raw_summary_payload: { "currency" => "EUR", "totalValue" => 1100,
      "cash" => { "availableToTrade" => 100, "inPies" => 0, "reservedForOrders" => 0 }, "investments" => { "currentValue" => 1000 } },
      raw_positions_payload: [ position ], raw_transactions_payload: [ { "reference" => "unknown", "type" => "TRANSFER", "amount" => 5 } ])
    @cash_provider.update!(raw_summary_payload: @portfolio.raw_summary_payload)
    assert_no_difference "Entry.count" do
      assert_raises(Trading212Account::Snapshot::Invalid) { @portfolio.trading212_item.process_accounts }
    end
    assert_equal previous, @portfolio.reload.last_processed_at
  end

  test "negative sell fill reverses cash direction and quantity" do
    sell = order
    sell["order"]["side"] = "SELL"
    sell["fill"]["quantity"] = "-1"
    @portfolio.update!(raw_orders_payload: [ sell ])
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    assert_equal(-1.to_d, @account.entries.trades.first.trade.qty)
    assert_equal(-100.to_d, @cash.entries.transactions.first.amount)
    assert_equal 0.to_d, @account.entries.sum(:amount)
  end

  test "foreign instrument settles the actual wallet amount and offsets the trade currency" do
    foreign = order
    foreign["order"]["instrument"]["currency"] = "USD"
    foreign["fill"]["price"] = "110"
    @portfolio.update!(raw_orders_payload: [ foreign ])
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    trade = @account.entries.trades.first
    assert_equal "USD", trade.currency
    assert_equal 110.to_d, trade.amount
    assert_in_delta 100.0 / 110, trade.trade.exchange_rate, 0.000001
    counterpart = @account.entries.transactions.first
    assert_equal trade.trade.exchange_rate, counterpart.transaction.exchange_rate
    assert_equal 100.to_d, @cash.entries.transactions.first.amount
    assert_equal 0.to_d, @account.entries.sum(:amount)
  end

  test "cash and portfolio processing rolls back as a pair if cash metadata conflicts" do
    summary = { "currency" => "EUR", "totalValue" => 1100,
      "cash" => { "availableToTrade" => 100, "inPies" => 0, "reservedForOrders" => 0 },
      "investments" => { "currentValue" => 1000 } }
    @portfolio.update!(raw_summary_payload: summary, raw_positions_payload: [ position ], raw_transactions_payload: [
      { "reference" => "bad", "type" => "DEPOSIT", "amount" => 1, "currency" => "EUR", "dateTime" => "2026-06-01T00:00:00Z" }
    ])
    @cash_provider.update!(raw_summary_payload: summary, statement_enrichments: { "bad" => { "amount" => "-999", "currency" => "EUR" } })
    assert_no_difference "Entry.count" do
      assert_raises(Trading212Account::Snapshot::Invalid) { @portfolio.trading212_item.reload.process_accounts }
    end
  end

  test "stale same day provider holdings are removed only after complete snapshot validation" do
    summary = { "currency" => "EUR", "totalValue" => 100,
      "cash" => { "availableToTrade" => 100, "inPies" => 0, "reservedForOrders" => 0 },
      "investments" => { "currentValue" => 0 } }
    @portfolio.update!(raw_summary_payload: summary, raw_positions_payload: [])
    security = Security.create!(ticker: "STALE", name: "Stale position")
    stale = @account.holdings.create!(security: security, date: Date.current, currency: "EUR", qty: 1, price: 10, amount: 10,
      account_provider: @portfolio.account_provider, external_id: "trading212_position_stale")
    Trading212Account::HoldingsProcessor.new(@portfolio).process
    assert_not Holding.exists?(stale.id)
    @portfolio.update!(raw_summary_payload: summary.deep_merge("investments" => { "currentValue" => 50 }))
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::HoldingsProcessor.new(@portfolio).process }
  end

  test "missing wallet settlement and disabled cash fail atomically in processor" do
    @portfolio.update!(raw_summary_payload: { "currency" => "EUR", "totalValue" => 1100,
      "cash" => { "availableToTrade" => 100, "inPies" => 0, "reservedForOrders" => 0 },
      "investments" => { "currentValue" => 1000 } }, raw_positions_payload: [ position ])
    missing = order
    missing["order"]["filledValue"] = "100"
    missing["fill"].delete("walletImpact")
    @portfolio.update!(raw_orders_payload: [ missing ])
    assert_no_difference "Entry.count" do
      assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::Processor.new(@portfolio).process }
    end
    # A rolled-back ActiveRecord transaction leaves associated Ruby objects
    # dirty; the next independent sync reloads its provider/account as well.
    @account.reload
    @portfolio.reload
    @portfolio.update!(raw_orders_payload: [ order ])
    @cash.update!(status: "disabled", disabled_at: Time.current)
    assert_no_difference "Entry.count" do
      assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::Processor.new(@portfolio).process }
    end
  end

  private

    def position
      { "instrument" => { "ticker" => "TEST_EQ", "currency" => "EUR" }, "quantity" => 10, "currentPrice" => 100,
        "walletImpact" => { "currency" => "EUR", "currentValue" => 1000 } }
    end

    def order
      { "order" => { "id" => "order", "side" => "BUY", "status" => "FILLED",
          "instrument" => { "ticker" => "TEST_EQ", "currency" => "EUR", "name" => "Test security" } },
        "fill" => { "id" => "fill", "quantity" => "1", "price" => "100", "filledAt" => "2026-06-05T12:00:00Z",
          "walletImpact" => { "currency" => "EUR", "netValue" => "-100" } } }
    end
end
