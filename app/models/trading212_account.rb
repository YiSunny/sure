class Trading212Account < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include Trading212Account::DataHelpers

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_orders_payload
    encrypts :raw_dividends_payload
    encrypts :raw_transactions_payload
    encrypts :raw_summary_payload
    encrypts :statement_enrichments
    encrypts :split_audit_payload
    encrypts :settlement_allocations
  end

  belongs_to :trading212_item
  has_many :trading212_statements, dependent: :destroy

  enum :kind, { combined: "combined", cash: "cash", portfolio: "portfolio" }, default: :combined

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :trading212_account_id, uniqueness: { scope: [ :trading212_item_id, :kind ], allow_nil: true }

  def sibling(kind)
    trading212_item.trading212_accounts.find_by(trading212_account_id: trading212_account_id, kind: kind)
  end

  def usable_account
    current_account unless current_account&.disabled? || current_account&.pending_deletion?
  end

  def snapshot
    Trading212Account::Snapshot.new(raw_summary_payload)
  end

  # Sync scheduling also takes this item lock. Keep connection-level mutations
  # ordered before provider/statement locks so an upload cannot race a split or
  # process only half of a newly configured pair.
  def with_connection_lock(&block)
    trading212_item.with_lock(&block)
  end

  def account_balance
    return current_balance unless cash? || portfolio?

    cash? ? snapshot.cash : snapshot.investments
  end

  # A summary is an assertion in a particular denomination, never permission
  # to relabel an established ledger (including protected historical entries).
  def validate_currency!(incoming_currency)
    Money::Currency.new(incoming_currency)
    currencies = [ current_account&.currency ]
    currencies << currency if persisted?
    return if currencies.compact.all? { |existing| existing == incoming_currency }

    raise Trading212Account::Snapshot::Invalid, I18n.t("trading212_split.currency_mismatch")
  end

  def linkable_to?(account)
    account.accountable_type == (cash? ? "Depository" : "Investment")
  end

  def activity_payload(name)
    source = cash? ? sibling("portfolio") : self
    Array(source&.public_send(name))
  end

  def statement_coverage
    dates = trading212_statements.applied.order(:coverage_start).pluck(:coverage_start, :coverage_end)
    { first: dates.filter_map(&:first).min, last: dates.filter_map(&:last).max,
      unclassified: current_account&.entries&.transactions&.joins("JOIN transactions t ON t.id = entries.entryable_id")
        &.where("t.extra -> 'trading212' ->> 'classification_pending' = 'true'")&.count || 0 }
  end

  def accounting_diagnostics
    source = cash? ? sibling("portfolio") : self
    orders = Array(source&.raw_orders_payload).select { |row| row.dig("order", "status") == "FILLED" }
    allocations = source&.settlement_allocations || {}
    unresolved = orders.count { |row| !allocations.key?((row.dig("fill", "id") || row.dig("order", "id")).to_s) }
    supported = [ "DEPOSIT", "WITHDRAW", "FEE", *Trading212Account::ActivitiesProcessor::INTEREST_TYPES ]
    unsupported = Array(source&.raw_transactions_payload).count { |row| !supported.include?(row["type"]) }
    reconciliation_difference = if portfolio? && raw_summary_payload.present?
      values = Array(raw_positions_payload).sum { |row| row.dig("walletImpact", "currentValue").to_d }
      snapshot.investments - snapshot.cash_in_pies - values
    end
    { processed_at: last_processed_at, fetched_at: last_positions_sync, reconciliation_difference: reconciliation_difference, currency: currency,
      stale: last_processed_at.nil? || last_processed_at < 24.hours.ago,
      sync_failed: trading212_item.sync_error.present?, unresolved_settlements: unresolved,
      unsupported_activities: unsupported }
  end

  def current_account
    account || linked_account
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "Trading212Account", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "Trading212Account##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "trading212",
      family: trading212_item.family,
      provider_key: "trading212"
    )
    nil
  end

  def instruments_map
    trading212_item.instruments_map
  end
end
