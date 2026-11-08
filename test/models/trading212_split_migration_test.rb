require "test_helper"

class Trading212SplitMigrationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @provider = trading212_accounts(:main_account)
    @provider.trading212_item.update!(family: @user.family)
    @account = @user.family.accounts.create!(name: "Broker", currency: "EUR", balance: 1000,
      owner: @user, accountable: Investment.new(subtype: "brokerage"))
    @provider.ensure_account_provider!(@account)
    @provider.update!(last_positions_sync: Time.current, currency: "EUR", raw_summary_payload: { "currency" => "EUR", "totalValue" => "1000",
      "cash" => { "availableToTrade" => "200", "inPies" => "0", "reservedForOrders" => "0" },
      "investments" => { "currentValue" => "800" } })
  end

  test "split preserves existing cash entry identity annotations and original anchor audit" do
    entry = @account.entries.create!(name: "My purchase", currency: "EUR", amount: "12.34", date: Date.new(2026, 6, 1),
      notes: "Receipt reference", source: "trading212", external_id: "trading212_transaction_reference",
      user_modified: true, entryable: Transaction.new(investment_activity_label: "Withdrawal", kind: "standard"))
    @account.set_current_balance(1000, schedule_sync: false)
    old_anchor_id = @account.entries.valuations.first.id
    old_id = entry.id
    old_transaction_id = entry.entryable_id
    cash = Trading212Account::Splitter.new(@provider, user: @user).apply!.current_account
    assert_equal cash.id, entry.reload.account_id
    assert_equal old_id, entry.id
    assert_equal old_transaction_id, entry.entryable_id
    assert_equal "Receipt reference", entry.notes
    assert_equal "My purchase", entry.name
    assert entry.user_modified?
    assert_equal old_anchor_id, @provider.reload.split_audit_payload.fetch("valuations").first.fetch("entry").fetch("id")
    assert_equal old_id, @provider.split_audit_payload.fetch("cash_entries").first.fetch("entry").fetch("id")
    assert_not Entry.exists?(old_anchor_id)
    assert_equal 800.to_d, @account.reload.current_anchor_balance
    assert_equal 200.to_d, cash.current_anchor_balance
  end

  test "invalid summary and manual cash activity abort without creating a sibling" do
    @account.entries.create!(name: "Manual adjustment", currency: "EUR", amount: 1, date: Date.current, entryable: Transaction.new)
    assert_no_difference [ "Trading212Account.count", "Account.count" ] do
      assert_raises(Trading212Account::Splitter::Conflict) { Trading212Account::Splitter.new(@provider, user: @user).apply! }
    end
    assert @provider.reload.combined?
    assert_equal 1000.to_d, @account.reload.balance
  end
end
