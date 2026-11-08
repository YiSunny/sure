require "test_helper"

class Trading212LegacyArchiveTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @provider = trading212_accounts(:main_account)
    @provider.trading212_item.update!(family: @user.family)
    @provider.update!(kind: "portfolio")
    @account = @user.family.accounts.create!(name: "Portfolio", currency: "USD", balance: 100,
      owner: @user, accountable: Investment.new)
    @provider.ensure_account_provider!(@account)
    @legacy = @user.family.accounts.create!(name: "Experimental", currency: "USD", balance: 999,
      owner: @user, accountable: Depository.new)
  end

  test "archives duplicate outside current and historical reports without deleting entries" do
    entry = @legacy.entries.create!(name: "Imported", date: Date.current, currency: "USD", amount: 10,
      import_locked: true, entryable: Transaction.new)
    archive = Trading212Account::LegacyArchive.new(@provider, legacy_account: @legacy, user: @user)
    assert_equal 1, archive.preview[:transactions_preserved]
    assert_no_difference "Entry.count" do
      archive.apply!
      archive.apply!
    end
    assert @legacy.reload.disabled?
    assert @legacy.exclude_from_reports?
    assert Entry.exists?(entry.id)
    assert_not BalanceSheet::HistoricalAccountScope.new(@user.family, user: @user).relation.exists?(id: @legacy.id)
    assert_equal "999.0", @provider.reload.split_audit_payload.fetch("legacy_archives").fetch(@legacy.id).fetch("account").fetch("balance")
  end

  test "requires review of existing transfer and refuses another owner's account" do
    outflow = @legacy.entries.create!(name: "Outflow", date: Date.current, currency: "USD", amount: 10, entryable: Transaction.new)
    inflow = @account.entries.create!(name: "Inflow", date: Date.current, currency: "USD", amount: -10, entryable: Transaction.new)
    Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "pending")
    archive = Trading212Account::LegacyArchive.new(@provider, legacy_account: @legacy, user: @user)
    assert_raises(Trading212Account::LegacyArchive::Conflict) { archive.apply! }
    assert @legacy.reload.active?
    @legacy.update!(owner: @user.family.users.where.not(id: @user.id).first)
    assert_raises(Trading212Account::LegacyArchive::Conflict) { archive.preview }
  end
end
