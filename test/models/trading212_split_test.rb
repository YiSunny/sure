require "test_helper"

class Trading212SplitTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @provider = trading212_accounts(:main_account)
    @provider.trading212_item.update!(family: @family)
    @account = @family.accounts.create!(name: "Broker", currency: "USD", balance: 1000, cash_balance: 200,
      owner: @user, accountable: Investment.new(subtype: "brokerage"))
    @provider.ensure_account_provider!(@account)
    @provider.update!(raw_summary_payload: summary, last_positions_sync: Time.current)
  end

  test "summary derives cash from total less portfolio and rejects incomplete or impossible data" do
    snapshot = Trading212Account::Snapshot.new(summary).validate!
    assert_equal 200.to_d, snapshot.cash
    assert_equal 800.to_d, snapshot.investments
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::Snapshot.new(summary.except("cash")).validate! }
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::Snapshot.new(summary.merge("totalValue" => "700")).validate! }
  end

  test "Spending Pot cash omitted from availableToTrade is included without adding Pie cash twice" do
    response = { "currency" => "EUR", "totalValue" => "10559.46",
      "cash" => { "availableToTrade" => "45.58", "reservedForOrders" => 0, "inPies" => "0.48" },
      "investments" => { "currentValue" => "10471.54" } }
    snapshot = Trading212Account::Snapshot.new(response).validate!
    assert_equal "87.92".to_d, snapshot.cash
    assert_equal "42.34".to_d, snapshot.cash - snapshot.available_to_trade
    assert_equal "0.48".to_d, snapshot.cash_in_pies
    assert_equal snapshot.total, snapshot.cash + snapshot.investments
    assert_nothing_raised do
      snapshot.validate_positions!([ { "walletImpact" => { "currency" => "EUR", "currentValue" => "10471.08" } } ])
    end
    assert_raises(Trading212Account::Snapshot::Invalid) do
      snapshot.validate_positions!([ { "walletImpact" => { "currency" => "EUR", "currentValue" => "10000" } } ])
    end
  end

  test "split moves cash once and preserves owner shares and total value" do
    share_user = @family.users.where.not(id: @user.id).first
    @account.account_shares.find_or_create_by!(user: share_user) { |s| s.permission = "read_only"; s.include_in_finances = true } if share_user
    entry = cash_entry
    splitter = Trading212Account::Splitter.new(@provider, user: @user)
    cash_provider = splitter.apply!
    assert_equal "portfolio", @provider.reload.kind
    cash = cash_provider.current_account
    assert_equal "Depository", cash.accountable_type
    assert_equal @user.id, cash.owner_id
    assert_equal 1000.to_d, cash.balance + @account.reload.balance
    assert_equal 60.to_d, @account.cash_balance
    assert_equal cash.id, entry.reload.account_id
    assert_nil entry.transaction.investment_activity_label
    assert_equal @account.account_shares.pluck(:user_id, :permission, :include_in_finances).sort,
      cash.account_shares.pluck(:user_id, :permission, :include_in_finances).sort
    assert_no_difference "Account.count" do
      assert_equal cash_provider, splitter.apply!
    end
  end

  test "split preserves disabled state and does not enqueue a provider sync" do
    @account.update!(status: "disabled", disabled_at: Time.current)
    @provider.trading212_item.expects(:sync_later).never
    cash = Trading212Account::Splitter.new(@provider, user: @user).apply!.current_account
    assert cash.disabled?
    assert_equal @account.disabled_at, cash.disabled_at
  end

  test "stale snapshot blocks a split without changing accounts" do
    @provider.update!(last_positions_sync: 2.days.ago)
    splitter = Trading212Account::Splitter.new(@provider, user: @user)
    assert splitter.preview[:stale]
    assert_no_difference "Account.count" do
      assert_raises(Trading212Account::Splitter::Conflict) { splitter.apply! }
    end
    assert @provider.reload.combined?
  end

  test "split refuses transfer conflicts and foreign user" do
    entry = cash_entry
    other = @family.accounts.create!(name: "Other", currency: "USD", balance: 0, owner: @user, accountable: Depository.new)
    inflow = other.entries.create!(entryable: Transaction.new, amount: -10, currency: "USD", date: entry.date, name: "Other")
    Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: entry.transaction, status: "confirmed")
    assert_raises(Trading212Account::Splitter::Conflict) { Trading212Account::Splitter.new(@provider, user: @user).apply! }
    assert @provider.reload.combined?
    foreign = users(:family_member).dup
    foreign.family_id = SecureRandom.uuid
    assert_raises(Trading212Account::Splitter::Conflict) { Trading212Account::Splitter.new(@provider, user: foreign).preview }
  end

  private

    def summary
      { "id" => "test", "currency" => "USD", "totalValue" => "1000",
        "cash" => { "availableToTrade" => "100", "inPies" => "60", "reservedForOrders" => "40" },
        "investments" => { "currentValue" => "800" } }
    end

    def cash_entry
      @account.entries.create!(name: "Withdrawal", amount: 10, currency: "USD", date: Date.current,
        source: "trading212", external_id: "trading212_transaction_test", entryable: Transaction.new(investment_activity_label: "Withdrawal"))
    end
end
