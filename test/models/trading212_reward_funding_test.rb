require "test_helper"

class Trading212RewardFundingTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.update!(currency: "EUR")
    @portfolio = trading212_accounts(:main_account)
    @portfolio.trading212_item.update!(family: @family)
    @portfolio.update!(kind: "portfolio", currency: "EUR", raw_orders_payload: [ order ], raw_dividends_payload: [], raw_transactions_payload: [ reward ], settlement_allocations: {})
    @account = @family.accounts.create!(name: "Portfolio", owner: @user, currency: "EUR", balance: 100, accountable: Investment.new)
    @portfolio.ensure_account_provider!(@account)
    @cash_provider = @portfolio.trading212_item.trading212_accounts.create!(kind: "cash", currency: "EUR", trading212_account_id: @portfolio.trading212_account_id)
    @cash = @family.accounts.create!(name: "Cash", owner: @user, currency: "EUR", balance: 10, accountable: Depository.new)
    @cash_provider.ensure_account_provider!(@cash)
    @cash_provider.update!(statement_enrichments: { "reward" => {
      "action" => "Spending cashback", "amount" => "-3.00", "currency" => "EUR", "name" => "Spending cashback", "api_type" => "DEPOSIT", "category" => "Cashback"
    } })
  end

  test "reviewed cashback funds Pie cash once and its later buy never debits Main cash" do
    allocation = Trading212Account::CashbackAllocation.new(@cash_provider)
    assert_no_difference "Entry.count" do
      2.times { allocation.review!(reference: "reward", evidence: "Owner confirmed allocation at this reward", actor: @user) }
      Trading212Account::Settlement.new(@portfolio).review!(reference: "fill", cash_amount: 0, evidence: "Owner confirmed Pie buy", actor: @user)
    end
    2.times do
      Trading212Account::ActivitiesProcessor.new(@portfolio).process
      Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    end
    assert_equal 2, @cash.entries.count
    assert_equal 2, @account.entries.count
    assert_equal 0.to_d, @cash.entries.sum(:amount), "Reward receipt and allocation cancel on Cash"
    assert_equal 0.to_d, @account.entries.sum(:amount), "Allocation funds the trade's cash cost"
    assert_equal 3.to_d, @account.trades.sum(:qty)
    assert_equal 1, Transfer.where(inflow_transaction_id: @account.transactions.select(:id)).count
    assert_equal 1, @cash.transactions.where(kind: "standard").count, "Exactly one reward income entry"
    totals = IncomeStatement.new(@family, user: @user, accounts: @family.accounts.where(id: [ @cash.id, @account.id ])).totals(date_range: Date.new(2026, 8, 1)..Date.new(2026, 8, 31))
    assert_equal Money.new(3, "EUR"), totals.income_money
    assert_equal Money.new(0, "EUR"), totals.expense_money
  end

  test "negative cashback and earlier unreviewed cashback are never auto allocated" do
    negative = reward.merge("reference" => "negative", "type" => "WITHDRAW", "amount" => "-1.29")
    @portfolio.update!(raw_transactions_payload: [ reward, negative ])
    @cash_provider.update!(statement_enrichments: @cash_provider.statement_enrichments.merge("negative" => {
      "action" => "Spending cashback", "amount" => "1.29", "currency" => "EUR", "name" => "Cashback reversal", "api_type" => "WITHDRAW"
    }))
    assert_raises(ArgumentError) { Trading212Account::CashbackAllocation.new(@cash_provider).review!(reference: "negative", evidence: "Unknown pot", actor: @user) }
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    assert_equal 2, @cash.entries.count
    assert_empty @account.entries
    assert_equal "1.29".to_d, @cash.entries.find_by!(external_id: "trading212_transaction_negative").amount
  end

  test "cashback reviews require exact statement API agreement and owner authorization" do
    subject = Trading212Account::CashbackAllocation.new(@cash_provider)
    assert_raises(ActiveRecord::RecordNotFound) { subject.review!(reference: "reward", evidence: "Checked", actor: users(:family_member)) }
    assert_raises(ArgumentError) { subject.review!(reference: "reward", evidence: "", actor: @user) }
    assert_raises(ArgumentError) { subject.review!(reference: "missing", evidence: "Checked", actor: @user) }
    @portfolio.update!(raw_transactions_payload: [ reward.merge("amount" => "4") ])
    assert_raises(ArgumentError) { subject.review!(reference: "reward", evidence: "Checked", actor: @user) }
    assert_empty @cash_provider.reload.split_audit_payload.fetch("cashback_allocations", {})
  end

  test "protected cashback allocation refuses repeat processing without changing existing legs" do
    Trading212Account::CashbackAllocation.new(@cash_provider).review!(reference: "reward", evidence: "Checked", actor: @user)
    processor = Trading212Account::ActivitiesProcessor.new(@cash_provider)
    processor.process
    leg = @cash.entries.find_by!(external_id: "trading212_cashback_out_trading212_transaction_reward")
    leg.update!(user_modified: true)
    before = leg.attributes
    assert_no_difference "Entry.count" do
      assert_raises(Trading212Account::Snapshot::Invalid) { processor.process }
    end
    assert_equal before, leg.reload.attributes
  end

  test "referral reward creates portfolio benefit not Main cash spending or personal contribution" do
    @portfolio.update!(raw_transactions_payload: [])
    settlement = Trading212Account::Settlement.new(@portfolio)
    settlement.review!(reference: "fill", cash_amount: 0, funding_type: "referral_reward", evidence: "Owner confirmed friend referral shares", actor: @user)
    2.times { Trading212Account::ActivitiesProcessor.new(@portfolio).process }
    assert_empty @cash.entries
    assert_equal 2, @account.entries.count
    assert_equal 0.to_d, @account.entries.sum(:amount)
    assert_equal "Other", @account.entries.transactions.sole.transaction.investment_activity_label
    assert_equal "Referral reward", @account.entries.transactions.sole.transaction.category.name
    totals = InvestmentStatement::Totals.new(@family, account_ids: [ @account.id ], date_range: Date.new(2026, 8, 1)..Date.new(2026, 8, 31)).call
    assert_equal 0.to_d, totals[:contributions]
    assert_equal 1, totals[:trades_count]
    assert_equal 0.to_d, totals[:dividends]
    assert_equal 0.to_d, totals[:interest]
  end

  test "referral review cannot relabel a sale or use Main cash" do
    subject = Trading212Account::Settlement.new(@portfolio)
    assert_raises(ArgumentError) { subject.review!(reference: "fill", cash_amount: 3, funding_type: "referral_reward", evidence: "Wrong", actor: @user) }
    sell = order.deep_merge("order" => { "side" => "SELL" })
    @portfolio.update!(raw_orders_payload: [ sell ])
    assert_raises(ArgumentError) { subject.review!(reference: "fill", cash_amount: 0, funding_type: "referral_reward", evidence: "Wrong", actor: @user) }
  end

  test "referral benefit is not automatically paired to an unrelated bank payment" do
    @portfolio.update!(raw_transactions_payload: [])
    Trading212Account::Settlement.new(@portfolio).review!(reference: "fill", cash_amount: 0,
      funding_type: "referral_reward", evidence: "Confirmed referral", actor: @user)
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    benefit = @account.entries.transactions.sole
    bank = @family.accounts.create!(name: "Bank", owner: @user, currency: "EUR", balance: 10, accountable: Depository.new)
    bank.entries.create!(date: benefit.date, amount: 3, currency: "EUR", name: "Unrelated bank payment", entryable: Transaction.new)
    @family.auto_match_transfers!
    assert_nil benefit.transaction.reload.transfer
  end

  test "foreign referral shares offset provider wallet impact and preserve the original quote" do
    foreign = order.deep_merge("order" => { "instrument" => { "currency" => "USD" } }, "fill" => { "price" => 2 })
    @portfolio.update!(raw_orders_payload: [ foreign ], raw_transactions_payload: [])
    Trading212Account::Settlement.new(@portfolio).review!(reference: "fill", cash_amount: 0,
      funding_type: "referral_reward", evidence: "Confirmed referral credit", actor: @user)
    Trading212Account::ActivitiesProcessor.new(@portfolio).process
    trade = @account.entries.trades.sole
    assert_equal "USD", trade.currency
    assert_equal 2.to_d, trade.trade.price
    assert_equal 6.to_d, trade.amount
    assert_equal 0.to_d, Balance::SyncCache.new(@account).get_entries(trade.date).sum(&:amount)
    assert_empty @cash.entries
  end

  test "reverting statement metadata after cashback funding review requires explicit reconciliation" do
    Trading212Account::CashbackAllocation.new(@cash_provider).review!(reference: "reward", evidence: "Checked", actor: @user)
    statement = @cash_provider.trading212_statements.create!(user: @user, checksum: "reviewed-reward", status: "applied",
      result: { "matched" => [ { "reference" => "reward" } ] })
    assert_raises(ArgumentError) { statement.revert!(actor: @user) }
    assert statement.reload.applied?
    assert @cash_provider.reload.split_audit_payload.dig("cashback_allocations", "reward")
  end

  private

    def order
      { "order" => { "id" => "order", "side" => "BUY", "status" => "FILLED", "instrument" => { "ticker" => "EXAMPLE_EQ", "currency" => "EUR" } },
        "fill" => { "id" => "fill", "quantity" => 3, "price" => 1, "filledAt" => "2026-08-10T12:00:00Z", "walletImpact" => { "netValue" => 3, "currency" => "EUR" } } }
    end

    def reward
      { "reference" => "reward", "type" => "DEPOSIT", "amount" => 3, "currency" => "EUR", "dateTime" => "2026-08-10T01:00:00Z" }
    end
end
