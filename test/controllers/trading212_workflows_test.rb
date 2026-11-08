require "test_helper"

class Trading212WorkflowsTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    sign_in @user
    @provider = trading212_accounts(:main_account)
    @provider.trading212_item.update!(family: @user.family)
    @account = @user.family.accounts.create!(name: "Broker", currency: "USD", balance: 1000,
      owner: @user, accountable: Investment.new(subtype: "brokerage"))
    @provider.ensure_account_provider!(@account)
    @provider.update!(last_positions_sync: Time.current, raw_summary_payload: { "currency" => "USD", "totalValue" => 1000,
      "cash" => { "availableToTrade" => 200, "inPies" => 0, "reservedForOrders" => 0 },
      "investments" => { "currentValue" => 800 } })
  end

  test "split preview is read only and creates siblings only on explicit confirmation" do
    assert_no_difference "Account.count" do
      get trading212_split_path(@provider)
    end
    assert_response :success
    assert_select "form[action=?]", trading212_splits_path
    assert_difference "Account.count", 1 do
      post trading212_splits_path, params: { id: @provider.id }
    end
    assert_redirected_to accounts_path
    assert @provider.reload.portfolio?
  end

  test "preview feature gate blocks writes and reads" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    assert_no_difference "Account.count" do
      post trading212_splits_path, params: { id: @provider.id }
    end
    assert_redirected_to root_path
    get trading212_split_path(@provider)
    assert_redirected_to root_path
  end

  test "read write sharing does not grant financial split control" do
    other = @user.family.users.where.not(id: @user.id).first
    assert other
    @account.update!(owner: other)
    @account.account_shares.find_or_create_by!(user: @user).update!(permission: "read_write", include_in_finances: true)
    assert_no_difference "Account.count" do
      post trading212_splits_path, params: { id: @provider.id }
    end
    assert_response :not_found
  end

  test "split rejects a provider from another family without revealing its account" do
    foreign = trading212_accounts(:pending_setup_account)
    foreign.trading212_item.update!(family_id: families(:empty).id)
    assert_no_difference "Account.count" do
      post trading212_splits_path, params: { id: foreign.id }
    end
    assert_response :not_found
  end

  test "statement upload cannot target another owner's read write shared cash" do
    cash_provider = Trading212Account::Splitter.new(@provider, user: @user).apply!
    other = @user.family.users.where.not(id: @user.id).first
    cash_provider.current_account.update!(owner: other)
    cash_provider.current_account.account_shares.find_or_create_by!(user: @user)
      .update!(permission: "read_write", include_in_finances: true)
    assert_no_difference "Trading212Statement.count" do
      post trading212_statements_path, params: { trading212_account_id: cash_provider.id,
        file: uploaded_file(filename: "history.csv", content_type: "text/csv") }
    end
    assert_response :not_found
  end

  test "admin cannot relink another owner's read write shared account" do
    other = @user.family.users.where.not(id: @user.id).first
    target = @user.family.accounts.create!(name: "Other owner's account", currency: "USD", balance: 0,
      owner: other, accountable: Investment.new)
    target.account_shares.find_or_create_by!(user: @user).update!(permission: "read_write", include_in_finances: true)
    candidate = @provider.trading212_item.trading212_accounts.create!(name: "Unlinked", currency: "USD", trading212_account_id: "unlinked")
    assert_no_difference "AccountProvider.count" do
      post link_existing_account_trading212_items_path, params: { account_id: target.id, trading212_account_id: candidate.id }
    end
    assert_redirected_to settings_providers_path
    assert_nil candidate.reload.current_account
  end

  test "statement upload previews without importing and applies only within selected account" do
    cash_provider = Trading212Account::Splitter.new(@provider, user: @user).apply!
    @provider.reload.update!(raw_transactions_payload: [
      { "reference" => "reward", "type" => "DEPOSIT", "amount" => 1, "currency" => "USD", "dateTime" => "2026-06-01T01:00:00Z" }
    ])
    csv = "Action,Time (UTC),ID,Gross Total,Currency (Gross Total)\nSpending cashback,2026-06-01 01:00:00+00:00,reward,1,USD\n"
    assert_no_difference "Entry.count" do
      assert_difference "Trading212Statement.count", 1 do
        post trading212_statements_path, params: { trading212_account_id: cash_provider.id,
          file: uploaded_file(filename: "history.csv", content_type: "text/csv", content: csv) }
      end
    end
    statement = cash_provider.trading212_statements.last
    follow_redirect!
    assert_response :success
    assert_select "th", text: "Proposed category"
    assert_select "th", text: "Posted date (preserved)"
    assert_select "td", text: /Inflow \+\$1\.00/
    assert_select "form[action=?]", apply_trading212_statement_path(statement, trading212_account_id: cash_provider.id)
    post apply_trading212_statement_path(statement), params: { trading212_account_id: cash_provider.id }
    assert_redirected_to account_path(cash_provider.current_account)
    assert statement.reload.applied?
    get trading212_statement_path(statement, trading212_account_id: cash_provider.id)
    assert_response :success
    assert_select "form[action=?]", revert_trading212_statement_path(statement, trading212_account_id: cash_provider.id)
  end

  test "combined account owner can upload preview apply and revert without splitting" do
    @provider.update!(raw_transactions_payload: [
      { "reference" => "purchase", "type" => "WITHDRAW", "amount" => -12, "currency" => "USD", "dateTime" => "2026-06-01T01:00:00Z" }
    ])
    Trading212Account::ActivitiesProcessor.new(@provider).process
    csv = "Action,Time (UTC),ID,Gross Total,Currency (Gross Total),Merchant name\nCard debit,2026-06-01 00:00:00+00:00,purchase,-12,USD,Example Shop\n"
    get account_path(@account)
    assert_select "a[href=?]", new_trading212_statement_path(trading212_account_id: @provider.id)
    assert_no_difference [ "Account.count", "Entry.count" ] do
      post trading212_statements_path, params: { trading212_account_id: @provider.id,
        file: uploaded_file(filename: "history.csv", content_type: "text/csv", content: csv) }
      follow_redirect!
      assert_response :success
      assert_select "td", text: "Example Shop"
      statement = @provider.trading212_statements.sole
      post apply_trading212_statement_path(statement), params: { trading212_account_id: @provider.id }
      assert_redirected_to account_path(@account)
      assert_equal "Example Shop", @account.entries.sole.name
      post revert_trading212_statement_path(statement), params: { trading212_account_id: @provider.id }
      assert statement.reload.preview?
    end
    assert @provider.reload.combined?
  end

  test "combined account upload rejects other owners foreign families and disabled preview features" do
    other = @user.family.users.where.not(id: @user.id).first
    @account.update!(owner: other)
    @account.account_shares.find_or_create_by!(user: @user).update!(permission: "read_write", include_in_finances: true)
    get new_trading212_statement_path(trading212_account_id: @provider.id)
    assert_response :not_found

    foreign = trading212_accounts(:pending_setup_account)
    foreign.trading212_item.update!(family_id: families(:empty).id)
    get new_trading212_statement_path(trading212_account_id: foreign.id)
    assert_response :not_found

    @account.update!(owner: @user)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get new_trading212_statement_path(trading212_account_id: @provider.id)
    assert_redirected_to root_path
    assert_no_difference "Trading212Statement.count" do
      post trading212_statements_path, params: { trading212_account_id: @provider.id,
        file: uploaded_file(filename: "history.csv", content_type: "text/csv") }
    end
    assert_redirected_to root_path
  end
end
