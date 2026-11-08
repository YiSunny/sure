require "test_helper"

class Trading212StatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @portfolio = trading212_accounts(:main_account)
    @portfolio.trading212_item.update!(family: @family)
    @portfolio.update!(kind: "portfolio", raw_transactions_payload: [
      { "reference" => "purchase", "type" => "WITHDRAW", "amount" => "-20.28", "currency" => "EUR", "dateTime" => "2026-06-07T09:00:00Z" },
      { "reference" => "reward", "type" => "DEPOSIT", "amount" => "0.30", "currency" => "EUR", "dateTime" => "2026-06-04T01:00:00Z" }
    ])
    @cash_provider = @portfolio.trading212_item.trading212_accounts.create!(kind: "cash",
      trading212_account_id: @portfolio.trading212_account_id, currency: "EUR", name: "Cash")
    @cash = @family.accounts.create!(name: "Cash", currency: "EUR", balance: 100, owner: @user, accountable: Depository.new)
    @cash_provider.ensure_account_provider!(@cash)
  end

  test "matches by reference despite four day date difference and never imports trades" do
    statement = build_statement
    preview = statement.preview_result
    assert_empty preview[:conflicts]
    assert_equal 2, preview[:matched].size
    assert_equal 1, preview[:skipped].size
    assert_equal "2026-06-07T09:00:00Z", preview[:matched].first["posted_timestamp"]
    assert_equal Time.iso8601("2026-06-03T09:00:00Z"), Time.iso8601(preview[:matched].first["purchase_timestamp"])
    statement.apply!(actor: @user)
    Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    purchase = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    assert_equal "Example Mobility", purchase.name
    assert_equal Date.new(2026, 6, 7), purchase.date
    assert_equal "Transportation", purchase.transaction.category.name
    assert_equal "Example Mobility", purchase.transaction.merchant.name
    reward = @cash.entries.find_by!(external_id: "trading212_transaction_reward")
    assert_equal "standard", reward.transaction.kind
    assert_nil reward.transaction.investment_activity_label
    assert_equal "Cashback", reward.transaction.category.name
    assert_no_difference "Entry.count" do
      statement.apply!(actor: @user)
      Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    end
    assert_equal "Example Mobility", purchase.reload.name
  end

  test "wrong account and duplicate reference block the entire batch" do
    statement = build_statement
    @portfolio.update!(raw_transactions_payload: [])
    assert_equal 2, statement.preview_result[:conflicts].size
    assert_raises(ArgumentError) { statement.apply!(actor: @user) }
    assert_empty @cash_provider.reload.statement_enrichments
    rows = statement.rows
    statement.update!(rows: rows + [ rows.first ])
    assert statement.preview_result[:conflicts].any? { |r| r[:reason] == "duplicate_reference" }
  end

  test "unknown action missing ID and changed amount are conflicts not guessed imports" do
    statement = build_statement
    rows = statement.rows
    rows[0]["gross"] = "-999"
    rows[1]["reference"] = ""
    statement.update!(rows: rows)
    assert_equal %w[amount_conflict missing_reference], statement.preview_result[:conflicts].map { |r| r[:reason] }
  end

  test "duplicate API references cannot be silently resolved by taking the last row" do
    data = @portfolio.raw_transactions_payload
    @portfolio.update!(raw_transactions_payload: data + [ data.first ])
    preview = build_statement.preview_result
    assert_equal "ambiguous_api_reference", preview[:conflicts].first[:reason]
  end

  test "amount and reference alone cannot enrich another entry type" do
    @cash.entries.create!(date: Date.new(2026, 6, 7), name: "Valuation", amount: "20.28", currency: "EUR",
      source: "trading212", external_id: "trading212_transaction_purchase", entryable: Valuation.new(kind: "reconciliation"))
    assert_equal "entry_type_conflict", build_statement.preview_result[:conflicts].first[:reason]
  end

  test "visible provider sync blocks statement application even with a stale cached status" do
    item = @portfolio.trading212_item
    item.syncs.create!(status: "pending")
    assert_raises(ArgumentError) { build_statement.apply!(actor: @user) }
    assert_empty @cash_provider.reload.statement_enrichments
  end

  test "parser rejects duplicate columns and non finite amounts" do
    assert_raises(ArgumentError) { Trading212Statement::Parser.new("Action,Action\nDeposit,Deposit\n").parse }
    assert_raises(ArgumentError) { Trading212Statement::Parser.new(csv.sub("-20.28", "NaN")).parse }
    assert_raises(ArgumentError) { Trading212Statement::Parser.new(csv.sub("2026-06-03 09:00:00+00:00", "2026-06-03 09:00:00")).parse }
    assert_raises(ArgumentError) { Trading212Statement::Parser.new(csv.b + "\xff".b).parse }
    assert_equal 3, Trading212Statement::Parser.new("\uFEFF" + csv).parse.size
  end

  test "unenriched API deposits remain unclassified cash movements not investment contributions" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_reward")
    assert_equal "unclassified", entry.transaction.kind
    assert_nil entry.transaction.investment_activity_label
    assert entry.transaction.extra.dig("trading212", "classification_pending")
    assert_equal 2, @cash_provider.statement_coverage[:unclassified]
    assert_nil @cash_provider.statement_coverage[:first]
  end

  test "unclassified posted cash affects balances but not income expenses daily spending or statistical reports" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    date_range = Date.new(2026, 6, 1)..Date.new(2026, 6, 30)
    scope = @family.transactions.where(entries: { account_id: @cash.id })
    rows = IncomeStatement::Totals.new(@family, transactions_scope: scope, date_range: date_range, included_account_ids: [ @cash.id ]).call
    assert_empty rows
    assert_empty IncomeStatement::DailyExpenseTotals.new(@family, transactions_scope: scope, date_range: date_range, included_account_ids: [ @cash.id ]).call
    assert_empty IncomeStatement::FamilyStats.new(@family, account_ids: [ @cash.id ]).call
    assert_empty IncomeStatement::CategoryStats.new(@family, account_ids: [ @cash.id ]).call
    assert_equal "19.98".to_d, Balance::SyncCache.new(@cash).get_entries(Date.new(2026, 6, 7)).sum(&:amount) + Balance::SyncCache.new(@cash).get_entries(Date.new(2026, 6, 4)).sum(&:amount)
    build_statement.apply!(actor: @user)
    rows = IncomeStatement::Totals.new(@family, transactions_scope: scope, date_range: date_range, included_account_ids: [ @cash.id ]).call
    assert_equal "20.28".to_d, rows.select { |r| r.classification == "expense" }.sum(&:total)
    assert_equal "0.30".to_d, rows.select { |r| r.classification == "income" }.sum(&:total)
  end

  test "protected legacy standard rows with pending metadata also remain out of reports" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    entry.transaction.update!(kind: "standard")
    entry.update!(user_modified: true)
    scope = @family.transactions.where(entries: { account_id: @cash.id })
    assert_empty IncomeStatement::Totals.new(@family, transactions_scope: scope, date_range: Date.new(2026, 6, 1)..Date.new(2026, 6, 30), included_account_ids: [ @cash.id ]).call
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    assert_equal "standard", entry.transaction.reload.kind
  end

  test "confirmed external funding is excluded without inventing a bank counterpart and reports remain provisional" do
    @portfolio.update!(raw_transactions_payload: [ { "reference" => "funding", "type" => "DEPOSIT", "amount" => 1000, "currency" => "EUR", "dateTime" => "2026-06-01T00:00:00Z" } ])
    content = "Action,Time (UTC),ID,Gross Total,Currency (Gross Total)\nDeposit,2026-06-01 00:00:00+00:00,funding,1000,EUR\n"
    statement = @cash_provider.trading212_statements.create!(user: @user, checksum: "funding", rows: Trading212Statement::Parser.new(content).parse)
    statement.apply!(actor: @user)
    Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    entry = @cash.entries.sole
    assert_equal "funds_movement", entry.transaction.kind
    assert_nil entry.transaction.transfer
    assert_equal 1, IncomeStatement.new(@family, user: @user).unresolved_trading212_count(date_range: entry.date..entry.date)
  end

  test "cash purchases and cashback cannot be auto matched to coincident bank movements" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    other = @family.accounts.create!(name: "Bank", currency: "EUR", balance: 0, owner: @user, accountable: Depository.new)
    other.entries.create!(name: "Unrelated", amount: "-20.28", currency: "EUR", date: Date.new(2026, 6, 7), entryable: Transaction.new)
    @family.auto_match_transfers!
    purchase = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    assert_nil purchase.transaction.transfer
    assert purchase.transaction.transfer_match_candidates.any?, "Human-reviewed matching must remain available"
    build_statement.apply!(actor: @user)
    @family.auto_match_transfers!
    assert_nil purchase.reload.transaction.transfer
  end

  test "overlapping statements are idempotent and changed classifications require review" do
    first = build_statement
    first.apply!(actor: @user)
    Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    second = @cash_provider.trading212_statements.create!(user: @user, checksum: "different-file",
      rows: [ first.rows.first ])
    assert_empty second.preview_result[:conflicts]
    assert_no_difference "Entry.count" do
      second.apply!(actor: @user)
      Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    end
    assert_equal 1, second.reload.result.fetch("before_values").size
    second.revert!(actor: @user)
    assert_equal first.checksum, @cash_provider.reload.statement_enrichments.fetch("purchase").fetch("statement_checksum")
    changed = first.rows.first.merge("merchant" => "Different merchant")
    third = @cash_provider.trading212_statements.create!(user: @user, checksum: "third-file", rows: [ changed ])
    assert_equal "previous_statement_conflict", third.preview_result[:conflicts].first[:reason]
  end

  test "user edited cash entries cannot be overwritten by statement upload or next sync" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    entry.update!(name: "User description", user_modified: true)
    statement = build_statement
    assert_equal "protected_entry", statement.preview_result[:conflicts].first[:reason]
    assert_raises(ArgumentError) { statement.apply!(actor: @user) }
    Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    assert_equal "User description", entry.reload.name
  end

  test "revert restores existing entry values and refuses newly synced classifications" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    before = entry.name
    statement = build_statement
    statement.apply!(actor: @user)
    assert_equal "Example Mobility", entry.reload.name
    statement.revert!(actor: @user)
    assert_equal before, entry.reload.name
    assert_nil entry.transaction.reload.merchant_id
    assert_empty @cash_provider.reload.statement_enrichments
    assert statement.reload.preview?
  end

  test "cashback clawback is an outflow not a contribution or invalid income" do
    @portfolio.update!(raw_transactions_payload: [
      { "reference" => "clawback", "type" => "WITHDRAW", "amount" => -1.29, "currency" => "EUR", "dateTime" => "2026-06-01T01:00:00Z" }
    ])
    content = "Action,Time (UTC),ID,Gross Total,Currency (Gross Total)\nSpending cashback,2026-06-01 01:00:00+00:00,clawback,-1.29,EUR\n"
    statement = @cash_provider.trading212_statements.create!(user: @user, checksum: "clawback", rows: Trading212Statement::Parser.new(content).parse)
    assert_empty statement.preview_result[:conflicts]
    statement.apply!(actor: @user)
    Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_clawback")
    assert_equal "1.29".to_d, entry.amount
    assert_equal "Cashback", entry.transaction.category.name
    assert_equal "standard", entry.transaction.kind
  end

  test "API amount changes after enrichment fail instead of silently reversing classification" do
    statement = build_statement
    statement.apply!(actor: @user)
    data = @portfolio.raw_transactions_payload
    data.first["amount"] = "-99"
    @portfolio.update!(raw_transactions_payload: data)
    assert_raises(Trading212Account::Snapshot::Invalid) { Trading212Account::ActivitiesProcessor.new(@cash_provider.reload).process }
  end

  test "revert refuses a changed category even without the legacy user modified flag" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    statement = build_statement
    statement.apply!(actor: @user)
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    entry.transaction.update!(category: Trading212Statement.category_for(@family, "User category"))
    assert_raises(ArgumentError) { statement.revert!(actor: @user) }
    assert statement.reload.applied?
    assert_equal "User category", entry.transaction.reload.category.name
  end

  test "revert respects explicit user locks even when values still match" do
    Trading212Account::ActivitiesProcessor.new(@cash_provider).process
    statement = build_statement
    statement.apply!(actor: @user)
    entry = @cash.entries.find_by!(external_id: "trading212_transaction_purchase")
    entry.transaction.lock_attr!(:category_id)
    assert_raises(ArgumentError) { statement.revert!(actor: @user) }
    assert statement.reload.applied?
  end

  private

    def csv
      <<~CSV
        Action,Time (UTC),ID,Gross Total,Currency (Gross Total),Merchant name,Merchant category
        Card debit,2026-06-03 09:00:00+00:00,purchase,-20.28,EUR,Example Mobility,AUTOMOBILE_RENTAL
        Spending cashback,2026-06-04 01:00:00+00:00,reward,0.30,EUR,,
        Limit buy,2026-06-05 10:00:00+00:00,trade,500,EUR,,
      CSV
    end

    def build_statement
      @cash_provider.trading212_statements.create!(user: @user, checksum: Digest::SHA256.hexdigest(csv),
        rows: Trading212Statement::Parser.new(csv).parse)
    end
end
