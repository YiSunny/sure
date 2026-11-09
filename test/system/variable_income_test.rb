require "application_system_test_case"

class VariableIncomeTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @series = @user.family.recurring_transactions.create!(name: "Example payroll", account: accounts(:depository),
      amount: -2000, currency: "USD", bill_type: "income", status: "active", manual: true,
      expected_day_of_month: Date.current.day, last_occurrence_date: Date.current, next_expected_date: Date.current)
    login_as @user
  end

  test "income editor saves an explicit variable amount choice" do
    visit edit_recurring_transaction_path(@series)
    select "Variable amount (estimate only)", from: "Income amount"
    click_button "Save income"
    assert_text I18n.t("recurring_transactions.update.success")
    assert @series.reload.variable_income?
    assert_equal "last", @series.amount_strategy
  end

  test "bills list shows the last variable paycheck rather than the original fallback" do
    @series.update!(variable_income: true, manual: false)
    october = @series.recurring_occurrences.create!(family: @user.family,
      original_due_on: Date.current - 1.month, due_on: Date.current - 1.month, currency: "USD")
    entry = @series.account.entries.create!(name: "Example payroll", amount: -750, currency: "USD", date: october.due_on, entryable: Transaction.new)
    RecurringTransaction::Allocator.new(october).allocate!(entry: entry)
    visit bills_path(view: "all")
    assert_text "~$750.00"
    assert_no_text "$2,000.00"
    visit bills_path(view: "paycheck")
    find("summary", text: I18n.t("bills.paycheck.manage")).click
    assert_text "~$750.00"
    assert_no_text "$2,000.00"
  end
end
