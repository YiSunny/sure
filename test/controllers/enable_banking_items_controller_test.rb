# frozen_string_literal: true

require "test_helper"
require "openssl"

class EnableBankingItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = @family.enable_banking_items.create!(
      name: "Test Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
    )
  end

  test "select_bank exposes ASPSP BIC in the searchable data attribute" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "ING-DiBa AG",
          country: "DE",
          bic: "INGDDEFF",
          beta: false,
          psu_types: [ "personal" ],
          auth_methods: [ { approach: "REDIRECT" } ]
        }
      ]
    )

    get select_bank_enable_banking_item_url(@item)

    assert_response :success
    haystack = @response.body[/data-bank-search="([^"]*)"/, 1]
    assert haystack, "Expected list items to render a data-bank-search attribute the client filter reads from"
    assert_includes haystack, "ingddeff",
      "Expected the searchable data attribute to include the BIC so users can find banks by BIC code"
    assert_includes haystack, "ing-diba ag",
      "Expected the searchable data attribute to still include the bank name (existing name-search behavior)"
  end

  test "authorize no longer blocks decoupled banks and proceeds to the hosted auth page" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "VR Bank in Holstein",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "decoupled_app", approach: "DECOUPLED" } ]
        }
      ]
    )
    Provider::EnableBanking.any_instance.stubs(:start_authorization).returns(
      url: "https://api.enablebanking.com/auth/redirect/abc",
      authorization_id: "auth_1"
    )

    post authorize_enable_banking_item_url(@item),
         params: { aspsp_name: "VR Bank in Holstein", psu_type: "personal" }

    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    assert_nil flash[:alert]
    assert_equal "DECOUPLED", @item.reload.aspsp_auth_approach
  end

  test "admin adds separate application from PEM upload without altering an existing connection" do
    @item.update!(session_id: "existing-session", session_expires_at: 1.month.from_now)
    original = @item.reload.attributes
    key = OpenSSL::PKey::RSA.new(2048).to_pem
    get new_application_enable_banking_items_path
    assert_response :success
    assert_select "input[type=file][name=?]", "enable_banking_item[client_certificate_file]"

    assert_difference "EnableBankingItem.count", 1 do
      post create_application_enable_banking_items_path, params: { enable_banking_item: {
        name: "Second application", country_code: "DE", application_id: "second-app",
        family_id: families(:empty).id,
        client_certificate_file: uploaded_file(filename: "application.pem", content_type: "application/x-pem-file", content: key)
      } }
    end
    assert_redirected_to settings_providers_path
    added = @family.enable_banking_items.find_by!(application_id: "second-app")
    assert_equal "Second application", added.name
    assert_equal key, added.client_certificate
    assert_nil added.session_id
    assert_equal original, @item.reload.attributes
    get connect_form_settings_providers_path(provider_key: "enable_banking")
    assert_response :success
    assert_select "a[href=?]", select_bank_enable_banking_item_path(added)
    assert_select "textarea[name=?]", "enable_banking_item[client_certificate]", text: ""
    assert_not_includes response.body, key
    assert_not_includes response.body, @item.client_certificate
  end

  test "invalid missing oversized and public-only key uploads do not create a connection or echo secrets" do
    key = OpenSSL::PKey::RSA.new(2048)
    [ nil, "not-a-private-key-sensitive-value", key.public_key.to_pem,
      key.export(OpenSSL::Cipher.new("aes-256-cbc"), "test-passphrase"),
      "x" * (EnableBankingItem::CredentialUpload::MAX_BYTES + 1) ].each do |content|
      upload = content && uploaded_file(filename: "application.pem", content_type: "application/x-pem-file", content: content)
      assert_no_difference "EnableBankingItem.count" do
        post create_application_enable_banking_items_path, params: { enable_banking_item: {
          name: "Second", country_code: "DE", application_id: "second-app", client_certificate_file: upload
        } }
      end
      assert_response :unprocessable_entity
      assert_not_includes response.body, content if content
    end
  end

  test "application validation failure shows the new form without writing or displaying the key" do
    key = OpenSSL::PKey::RSA.new(2048).to_pem
    assert_no_difference "EnableBankingItem.count" do
      post create_application_enable_banking_items_path, params: { enable_banking_item: {
        name: "Second", country_code: "DE", application_id: "",
        client_certificate_file: uploaded_file(filename: "key.pem", content_type: "application/x-pem-file", content: key)
      } }
    end
    assert_response :unprocessable_entity
    assert_not_includes response.body, key
  end

  test "members cannot open or submit the additional application form" do
    sign_in users(:family_member)
    get new_application_enable_banking_items_path
    assert_redirected_to accounts_path
    assert_no_difference "EnableBankingItem.count" do
      post create_application_enable_banking_items_path, params: { enable_banking_item: { name: "Blocked" } }
    end
    assert_redirected_to accounts_path
  end

  test "additional bank connection copies credentials from the selected application only" do
    second = @family.enable_banking_items.create!(name: "Second", country_code: "DE", application_id: "second-app",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem)
    original = @item.reload.attributes
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(aspsps: [ { name: "Example Bank", psu_types: [ "personal" ] } ])
    Provider::EnableBanking.any_instance.stubs(:start_authorization).returns(
      url: "https://api.enablebanking.com/auth/redirect/example", authorization_id: "new-auth")
    assert_difference "EnableBankingItem.count", 1 do
      post authorize_enable_banking_item_path(second), params: { aspsp_name: "Example Bank", new_connection: true }
    end
    assert_redirected_to "https://api.enablebanking.com/auth/redirect/example"
    copy = @family.enable_banking_items.find_by!(authorization_id: "new-auth")
    assert_equal second.name, copy.name
    assert_equal second.application_id, copy.application_id
    assert_equal second.client_certificate, copy.client_certificate
    assert_equal original, @item.reload.attributes
  end

  test "admin cannot authorize another family's application" do
    foreign = families(:empty).enable_banking_items.create!(name: "Foreign", country_code: "DE", application_id: "foreign",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem)
    assert_no_difference "EnableBankingItem.count" do
      post authorize_enable_banking_item_path(foreign), params: { aspsp_name: "Example Bank", new_connection: true }
    end
    assert_response :not_found
  end

  test "second admin completes account setup as herself rather than the first family admin" do
    second_admin = users(:family_member)
    second_admin.update!(role: "admin")
    sign_in second_admin
    provider_account = @item.enable_banking_accounts.create!(uid: "second-account", name: "Second person's bank", currency: "EUR", current_balance: 50)
    EnableBankingItem.any_instance.stubs(:sync_later)
    post complete_account_setup_enable_banking_item_path(@item), params: { account_types: { provider_account.id => "Depository" } }
    assert_redirected_to accounts_path
    assert_equal second_admin, provider_account.reload.current_account.owner
  end
end
