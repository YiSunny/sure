require "application_system_test_case"

class Trading212WorkflowTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @provider = trading212_accounts(:main_account)
    @provider.trading212_item.update!(family: @user.family)
    @account = @user.family.accounts.create!(name: "Example Trading 212", currency: "USD", balance: 1000,
      owner: @user, accountable: Investment.new(subtype: "brokerage"))
    @provider.ensure_account_provider!(@account)
    @provider.update!(last_positions_sync: Time.current, raw_summary_payload: { "currency" => "USD", "totalValue" => 1000,
      "cash" => { "availableToTrade" => 200, "inPies" => 0, "reservedForOrders" => 0 },
      "investments" => { "currentValue" => 800 } }, raw_transactions_payload: [
        { "reference" => "cashback", "type" => "DEPOSIT", "amount" => 1, "currency" => "USD", "dateTime" => "2026-06-01T01:00:00Z" }
      ])
    login_as @user
  end

  test "owner can preview split then upload original CSV and apply cash classification" do
    visit trading212_split_path(@provider)
    assert_text "Separate Trading 212 cash and portfolio"
    click_button "Create coordinated Cash and Portfolio accounts"
    assert_current_path accounts_path
    assert_text "Example Trading 212 — Cash"
    assert_text "Example Trading 212 — Portfolio"
    cash_provider = @provider.reload.sibling("cash")
    assert cash_provider
    visit new_trading212_statement_path(trading212_account_id: cash_provider.id)
    Tempfile.create([ "trading212", ".csv" ]) do |file|
      file.write("Action,Time (UTC),ID,Gross Total,Currency (Gross Total)\nSpending cashback,2026-06-01 01:00:00+00:00,cashback,1,USD\n")
      file.flush
      attach_file "History CSV", file.path
      click_button "Preview"
      assert_text "Spending cashback"
      assert_text "enrich_on_next_sync"
      click_button "Apply reviewed classifications"
      assert_current_path account_path(cash_provider.current_account)
      assert_text "Trading 212 CSV coverage"
    end
    assert_equal "Spending cashback", cash_provider.reload.statement_enrichments.fetch("cashback").fetch("action")
    assert @provider.portfolio?
    assert_equal "Depository", cash_provider.current_account.accountable_type
  end

  test "owner can upload a CSV on a combined account without splitting" do
    visit account_path(@account)
    click_link "Enrich Trading 212 cash from history CSV"
    assert_text "No Cash/Portfolio split is needed"
    Tempfile.create([ "trading212-combined", ".csv" ]) do |file|
      file.write("Action,Time (UTC),ID,Gross Total,Currency (Gross Total)\nSpending cashback,2026-06-01 01:00:00+00:00,cashback,1,USD\n")
      file.flush
      attach_file "History CSV", file.path
      click_button "Preview"
      assert_text "Spending cashback"
      click_button "Apply reviewed classifications"
      assert_current_path account_path(@account)
      assert_text "Trading 212 CSV coverage"
    end
    assert @provider.reload.combined?
    assert_equal "Spending cashback", @provider.statement_enrichments.fetch("cashback").fetch("action")
  end
end
