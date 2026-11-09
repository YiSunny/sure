require "application_system_test_case"
require "openssl"

class EnableBankingApplicationsTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @existing = @user.family.enable_banking_items.create!(name: "First application", country_code: "DE", application_id: "first-app",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem, session_id: "first-session", session_expires_at: 1.month.from_now)
    login_as @user
  end

  test "admin uploads a second application's private key without replacing the first connection" do
    original = @existing.attributes
    visit connect_form_settings_providers_path(provider_key: "enable_banking")
    click_link "Add another Enable Banking application"
    key = OpenSSL::PKey::RSA.new(2048).to_pem
    Tempfile.create([ "example-application", ".pem" ]) do |file|
      file.write(key)
      file.flush
      within "dialog[open]" do
        fill_in "Application label", with: "Second application"
        select "🇩🇪 Germany", from: "Country"
        fill_in "Application ID", with: "second-app"
        attach_file "Private key file (.pem)", file.path
        click_button "Save separate application"
      end
      assert_current_path settings_providers_path
      assert_text "Application saved"
    end
    visit connect_form_settings_providers_path(provider_key: "enable_banking")
    assert_text "Second application"
    assert_text "Application ID: second-app"
    new_item = @user.family.enable_banking_items.find_by!(application_id: "second-app")
    assert_selector "a[href='#{select_bank_enable_banking_item_path(new_item)}']"
    assert_equal key, new_item.client_certificate
    assert_equal original, @existing.reload.attributes
  end
end
