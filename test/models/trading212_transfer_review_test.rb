require "test_helper"

class Trading212TransferReviewTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @provider = trading212_accounts(:main_account)
    @provider.trading212_item.update!(family: @user.family)
    @provider.update!(kind: "cash")
    @cash = @user.family.accounts.create!(name: "Cash", currency: "USD", balance: 0, owner: @user, accountable: Depository.new)
    @provider.ensure_account_provider!(@cash)
    @legacy = @user.family.accounts.create!(name: "Duplicate", currency: "USD", balance: 0, owner: @user, accountable: Depository.new)
    @bank = @user.family.accounts.create!(name: "Bank", currency: "USD", balance: 0, owner: @user, accountable: Depository.new)
    @legacy_entry = @legacy.entries.create!(name: "Legacy deposit", date: Date.current, currency: "USD", amount: -100, entryable: Transaction.new(kind: "funds_movement"))
    bank_entry = @bank.entries.create!(name: "Transfer out", date: Date.current, currency: "USD", amount: 100, entryable: Transaction.new(kind: "funds_movement"))
    @transfer = Transfer.create!(inflow_transaction: @legacy_entry.transaction, outflow_transaction: bank_entry.transaction, status: "pending")
    @canonical = @cash.entries.create!(name: "Deposit", date: Date.current, currency: "USD", amount: -100,
      source: "trading212", external_id: "trading212_transaction_exact", entryable: Transaction.new(extra: { trading212_statement: { action: "Deposit" } }))
    @review = Trading212Account::TransferReview.new(@provider, legacy_account: @legacy, user: @user)
  end

  test "explicit exact reference reattachment preserves transfer and counterpart identity" do
    counterpart_id = @transfer.outflow_transaction_id
    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      @review.reattach!(transfer_id: @transfer.id, legacy_entry_id: @legacy_entry.id, reference: "exact")
    end
    assert_equal @canonical.entryable_id, @transfer.reload.inflow_transaction_id
    assert_equal counterpart_id, @transfer.outflow_transaction_id
    assert @transfer.pending?
    assert_equal "standard", @legacy_entry.transaction.reload.kind
    assert_equal "funds_movement", @canonical.transaction.reload.kind
    assert_equal 1, @provider.reload.split_audit_payload.fetch("transfer_reviews").size
  end

  test "refuses rewards different amounts wrong references and cross owner counterparts" do
    @canonical.transaction.update!(extra: { trading212_statement: { action: "Spending cashback" } })
    assert_raises(Trading212Account::TransferReview::Conflict) { reattach }
    @canonical.transaction.update!(extra: { trading212_statement: { action: "Deposit" } })
    @canonical.update!(amount: -99)
    assert_raises(Trading212Account::TransferReview::Conflict) { reattach }
    @canonical.update!(amount: -100)
    @bank.update!(owner: @user.family.users.where.not(id: @user.id).first)
    assert_raises(Trading212Account::TransferReview::Conflict) { reattach }
    assert_equal @legacy_entry.entryable_id, @transfer.reload.inflow_transaction_id
  end

  test "reattachment respects counterpart classification locks" do
    @transfer.outflow_transaction.lock_attr!(:kind)
    assert_raises(Trading212Account::TransferReview::Conflict) { reattach }
    assert_equal @legacy_entry.entryable_id, @transfer.reload.inflow_transaction_id
    assert_empty @provider.reload.split_audit_payload
  end

  private

    def reattach
      @review.reattach!(transfer_id: @transfer.id, legacy_entry_id: @legacy_entry.id, reference: "exact")
    end
end
