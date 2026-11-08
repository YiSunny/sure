require "test_helper"

class Trading212ItemImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = trading212_items(:configured_item)
  end

  test "import creates trading212_account with fetched data" do
    provider = mock("trading212_provider")
    provider.expects(:fetch_instruments).returns([
      { "ticker" => "AAPL_US_EQ", "shortName" => "Apple Inc.", "currencyCode" => "USD" }
    ])
    provider.expects(:fetch_account_summary).returns({
      "id" => "t212_acc_new",
      "totalValue" => "15000.00",
      "cash" => { "availableToTrade" => "2000.00" }
    })
    provider.expects(:fetch_positions).returns([
      { "instrument" => { "ticker" => "AAPL_US_EQ" }, "quantity" => "10", "currentPrice" => "175.00" }
    ])
    provider.expects(:fetch_all_orders).returns([
      { "order" => { "id" => "o1", "status" => "FILLED", "side" => "BUY" } }
    ])
    provider.expects(:fetch_all_dividends).returns([
      { "reference" => "d1", "amount" => "10.00" }
    ])
    provider.expects(:fetch_all_transactions).returns([
      { "reference" => "t1", "type" => "DEPOSIT", "amount" => "1000.00" }
    ])

    importer = Trading212Item::Importer.new(@item, provider: provider)
    result = importer.import

    assert_equal({ success: true }, result)

    account = @item.trading212_accounts.find_by(trading212_account_id: "t212_acc_new")
    assert_not_nil account
    assert_equal BigDecimal("15000.00"), account.current_balance
    assert_equal BigDecimal("2000.00"), account.cash_balance
    assert account.raw_positions_payload.present?
    assert account.raw_orders_payload.present?
    assert account.raw_dividends_payload.present?
    assert account.raw_transactions_payload.present?
  end

  test "authoritative summary currency is used for new discoveries" do
    provider = stub(fetch_instruments: [], fetch_account_summary: { "id" => "new-eur", "currency" => "EUR", "totalValue" => 100 },
      fetch_positions: [], fetch_all_orders: [], fetch_all_dividends: [], fetch_all_transactions: [])
    Trading212Item::Importer.new(@item, provider: provider).import
    assert_equal "EUR", @item.trading212_accounts.find_by!(trading212_account_id: "new-eur").currency
  end

  test "currency mismatch preserves established accounts protected entries and cached data" do
    established = trading212_accounts(:main_account)
    account = @family.accounts.create!(name: "Established", currency: "USD", balance: 100, accountable: Investment.new)
    established.ensure_account_provider!(account)
    entry = account.entries.create!(name: "Protected", date: Date.current, amount: -100, currency: "USD",
      import_locked: true, entryable: Transaction.new)
    before = established.attributes
    provider = mock("mismatched provider")
    provider.expects(:fetch_instruments).returns([])
    provider.expects(:fetch_account_summary).returns({ "id" => established.trading212_account_id, "currency" => "EUR", "totalValue" => 120 })
    provider.expects(:fetch_positions).never
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Item::Importer.new(@item, provider: provider).import }
    assert_equal before, established.reload.attributes
    assert_equal "USD", account.reload.currency
    assert_equal "USD", entry.reload.currency
  end

  test "import updates existing account on subsequent sync" do
    existing = @item.trading212_accounts.create!(
      name: "Existing Account",
      trading212_account_id: "t212_acc_existing",
      currency: "USD",
      current_balance: BigDecimal("1000.00"),
      cash_balance: BigDecimal("100.00")
    )

    provider = mock("trading212_provider")
    provider.expects(:fetch_instruments).returns([])
    provider.expects(:fetch_account_summary).returns({
      "id" => "t212_acc_existing",
      "totalValue" => "12000.00",
      "cash" => { "availableToTrade" => "1500.00" }
    })
    provider.expects(:fetch_positions).returns([])
    provider.expects(:fetch_all_orders).returns([])
    provider.expects(:fetch_all_dividends).returns([])
    provider.expects(:fetch_all_transactions).returns([])

    assert_no_difference "Trading212Account.count" do
      Trading212Item::Importer.new(@item, provider: provider).import
    end

    existing.reload
    assert_equal BigDecimal("12000.00"), existing.current_balance
    assert_equal BigDecimal("1500.00"), existing.cash_balance
  end

  test "import stores instruments payload on item" do
    instruments = [
      { "ticker" => "AAPL_US_EQ", "shortName" => "Apple Inc." },
      { "ticker" => "TSLA_US_EQ", "shortName" => "Tesla Inc." }
    ]

    provider = mock("trading212_provider")
    provider.expects(:fetch_instruments).returns(instruments)
    provider.expects(:fetch_account_summary).returns({
      "id" => "t212_acc_inst",
      "totalValue" => "5000.00",
      "cash" => { "availableToTrade" => "500.00" }
    })
    provider.expects(:fetch_positions).returns([])
    provider.expects(:fetch_all_orders).returns([])
    provider.expects(:fetch_all_dividends).returns([])
    provider.expects(:fetch_all_transactions).returns([])

    Trading212Item::Importer.new(@item, provider: provider).import

    assert_equal 2, @item.reload.raw_instruments_payload.size
  end

  test "import falls back to cached instruments on fetch failure" do
    @item.update!(raw_instruments_payload: [
      { "ticker" => "CACHED_US_EQ", "shortName" => "Cached Inc." }
    ])

    provider = mock("trading212_provider")
    provider.expects(:fetch_instruments).raises(StandardError.new("Network error"))
    provider.expects(:fetch_account_summary).returns({
      "id" => "t212_acc_cache",
      "totalValue" => "5000.00",
      "cash" => { "availableToTrade" => "500.00" }
    })
    provider.expects(:fetch_positions).returns([])
    provider.expects(:fetch_all_orders).returns([])
    provider.expects(:fetch_all_dividends).returns([])
    provider.expects(:fetch_all_transactions).returns([])

    # Should not raise
    result = Trading212Item::Importer.new(@item, provider: provider).import
    assert_equal({ success: true }, result)
  end

  test "split sync refreshes both siblings without creating another combined account" do
    portfolio = @item.trading212_accounts.create!(kind: "portfolio", name: "My Portfolio", currency: "EUR", trading212_account_id: "split")
    cash = @item.trading212_accounts.create!(kind: "cash", name: "My Cash", currency: "EUR", trading212_account_id: "split")
    summary = { "id" => "split", "currency" => "EUR", "totalValue" => "10559.46",
      "cash" => { "availableToTrade" => "45.58", "inPies" => "0.48", "reservedForOrders" => 0 },
      "investments" => { "currentValue" => "10471.54" } }
    provider = mock("provider")
    provider.expects(:fetch_instruments).returns([])
    provider.expects(:fetch_account_summary).returns(summary)
    provider.expects(:fetch_positions).returns([ { "walletImpact" => { "currency" => "EUR", "currentValue" => "10471.08" } } ])
    provider.expects(:fetch_all_orders).returns([])
    provider.expects(:fetch_all_dividends).returns([])
    provider.expects(:fetch_all_transactions).returns([])
    assert_no_difference "Trading212Account.count" do
      Trading212Item::Importer.new(@item, provider: provider).import
    end
    assert_equal "My Portfolio", portfolio.reload.name
    assert_equal "87.92".to_d, cash.reload.account_balance
    assert_equal summary, cash.raw_summary_payload
    assert_equal "10471.54".to_d, portfolio.account_balance
  end
end
