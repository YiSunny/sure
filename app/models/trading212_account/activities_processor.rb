class Trading212Account::ActivitiesProcessor
  include Trading212Account::DataHelpers

  # T212 transaction types that map to cash flows
  DEPOSIT_TYPE = "DEPOSIT".freeze
  WITHDRAW_TYPE = "WITHDRAW".freeze
  INTEREST_TYPES = %w[INTEREST INTEREST_ON_FREE_CASH LENDING_INTEREST].freeze
  FEE_TYPE = "FEE".freeze

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    return { trades: 0, dividends: 0, transactions: 0 } unless account.present?

    trade_count = @trading212_account.cash? ? 0 : @trading212_account.activity_payload(:raw_orders_payload).sum do |order|
      process_order(order.with_indifferent_access) ? 1 : 0
    end

    dividend_count = @trading212_account.portfolio? ? 0 : @trading212_account.activity_payload(:raw_dividends_payload).sum do |dividend|
      process_dividend(dividend.with_indifferent_access) ? 1 : 0
    end

    transaction_count = @trading212_account.portfolio? ? 0 : @trading212_account.activity_payload(:raw_transactions_payload).sum do |transaction|
      process_cash_transaction(transaction.with_indifferent_access) ? 1 : 0
    end

    { trades: trade_count, dividends: dividend_count, transactions: transaction_count }
  end

  private

    def account
      @trading212_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @trading212_account.currency
    end

    def process_order(raw)
      # T212 orders response is {order: {...}, fill: {...}}
      order = (raw[:order] || {}).with_indifferent_access
      fill  = (raw[:fill]  || {}).with_indifferent_access

      return false unless order[:status].to_s.upcase == "FILLED"

      instrument = (order[:instrument] || {}).with_indifferent_access
      t212_ticker = instrument[:ticker].presence || order[:ticker].to_s
      return false if t212_ticker.blank?

      return false unless %w[BUY SELL].include?(order[:side].to_s.upcase)
      filled_quantity = parse_decimal(fill[:quantity])&.abs
      fill_price      = parse_decimal(fill[:price])

      return false unless filled_quantity && fill_price
      return false if filled_quantity.zero?

      isin     = instrument[:isin].presence
      ticker   = standard_ticker(t212_ticker)
      name     = instrument[:name].presence || ticker
      security = resolve_security_direct(isin, ticker, name)
      return false unless security

      is_buy         = order[:side].to_s.upcase == "BUY"
      activity_label = is_buy ? "Buy" : "Sell"
      signed_quantity = is_buy ? filled_quantity : -filled_quantity
      instrument_ccy, fill_price = normalize_minor_units(instrument[:currency].presence || currency, fill_price)
      amount, exchange_rate = trade_amount_and_rate(order, fill, instrument_ccy, fill_price * filled_quantity)
      amount = is_buy ? amount : -amount

      date           = parse_date(fill[:filledAt] || order[:createdAt]) || Date.current
      order_id       = (fill[:id] || order[:id]).to_s
      return false if order_id.blank?
      external_id    = "trading212_order_#{order_id}"

      existing = account.entries.find_by(external_id: external_id, source: "trading212")
      raise Trading212Account::Snapshot::Invalid, "Trade reference collides with another entry type" if existing && !existing.trade?
      raise Trading212Account::Snapshot::Invalid, "Protected trade requires manual review" if @trading212_account.portfolio? && existing&.protected_from_sync?
      if @trading212_account.portfolio? && existing && (%i[amount currency date].any? { |attribute| existing.locked?(attribute) } ||
          %i[qty price currency exchange_rate].any? { |attribute| existing.trade.locked?(attribute) })
        raise Trading212Account::Snapshot::Invalid, "Locked trade requires manual review"
      end
      entry = import_adapter.import_trade(
        external_id:    external_id,
        security:       security,
        quantity:       signed_quantity,
        price:          fill_price,
        amount:         amount,
        currency:       instrument_ccy,
        date:           date,
        name:           build_order_name(security.ticker, signed_quantity),
        source:         "trading212",
        activity_label: activity_label,
        exchange_rate: exchange_rate
      )

      Trading212Account::Settlement.new(@trading212_account).process(entry, fill) if @trading212_account.portfolio?

      true
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Trading212Account::ActivitiesProcessor - Failed to process order #{raw.dig(:order, :id)}: #{e.message}",
        source: "trading212",
        family: @trading212_account.trading212_item.family,
        provider_key: "trading212",
        metadata: { order_id: raw.dig(:order, :id), trading212_account_id: @trading212_account.id }
      )
      raise unless @trading212_account.combined?
      false
    end

    def process_dividend(dividend)
      reference = dividend[:reference].to_s
      return false if reference.blank?

      amount = parse_decimal(dividend[:amount])
      return false unless amount&.finite? && !amount.zero?

      t212_ticker = dividend[:ticker].to_s
      security = t212_ticker.present? ? resolve_security_for_ticker(t212_ticker) : nil

      date = parse_date(dividend[:paidOn]) || Date.current


      import_adapter.import_transaction(
        external_id: "trading212_dividend_#{reference}",
        amount: -amount,
        currency: currency,
        date: date,
        name: build_dividend_name(security),
        source: "trading212",
        allow_heuristic_matching: @trading212_account.combined?,
        investment_activity_label: "Dividend",
        extra: {
          security_id: security&.id,
          trading212: {
            reference: reference,
            ticker: t212_ticker,
            quantity: dividend[:quantity],
            gross_amount_per_share: dividend[:grossAmountPerShare],
            type: dividend[:type]
          }.compact
        }
      )

      true
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Trading212Account::ActivitiesProcessor - Failed to process dividend #{dividend[:reference]}: #{e.message}",
        source: "trading212",
        family: @trading212_account.trading212_item.family,
        provider_key: "trading212",
        metadata: { reference: dividend[:reference], trading212_account_id: @trading212_account.id }
      )
      raise unless @trading212_account.combined?
      false
    end

    def process_cash_transaction(transaction)
      reference = transaction[:reference].to_s
      return false if reference.blank?

      type = transaction[:type].to_s.upcase
      amount = parse_decimal(transaction[:amount])
      return false unless amount && !amount.zero?

      label, signed_amount = classify_transaction(type, amount)
      unless label
        DebugLogEntry.capture(category: "sync", level: "warn", source: "trading212", provider_key: "trading212",
          family: @trading212_account.trading212_item.family,
          message: "Unsupported Trading 212 cash activity; no financial direction guessed",
          metadata: { type: type, reference: reference, trading212_account_id: @trading212_account.id })
        raise Trading212Account::Snapshot::Invalid, I18n.t("trading212_split.unsupported_history") unless @trading212_account.combined?
        return false
      end

      return process_split_cash(transaction, signed_amount) if @trading212_account.cash?

      date = parse_date(transaction[:dateTime]) || Date.current
      deposit = type == DEPOSIT_TYPE

      # A DEPOSIT is the owner's own money arriving (almost always a bank
      # top-up), so it is a funds movement: neither income nor spending.
      # Buying securities with it is a separate trade, and trades never count
      # as spending. Without the Contribution label the import adapter does not
      # force the budgeted investment_contribution kind, and transfer matching
      # can still pair it with the bank leg.
      entry = import_adapter.import_transaction(
        external_id: "trading212_transaction_#{reference}",
        amount: signed_amount,
        currency: currency,
        date: date,
        name: deposit ? "Deposit" : label,
        source: "trading212",
        investment_activity_label: deposit ? nil : label,
        kind: deposit ? "funds_movement" : nil,
        extra: {
          trading212: {
            reference: reference,
            type: type,
            amount: transaction[:amount]
          }.compact
        }
      )
      reset_legacy_contribution!(entry) if deposit

      true
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Trading212Account::ActivitiesProcessor - Failed to process transaction #{transaction[:reference]}: #{e.message}",
        source: "trading212",
        family: @trading212_account.trading212_item.family,
        provider_key: "trading212",
        metadata: { reference: transaction[:reference], trading212_account_id: @trading212_account.id }
      )
      raise unless @trading212_account.combined?
      false
    end

    def classify_transaction(type, amount)
      case type
      when DEPOSIT_TYPE
        [ "Contribution", -amount.abs ]
      when WITHDRAW_TYPE
        [ "Withdrawal", amount.abs ]
      when *INTEREST_TYPES
        [ "Interest", -amount.abs ]
      when FEE_TYPE
        [ "Fee", amount.abs ]
      end
    end

    # Backported from upstream #4140: wallet netValue is in wallet currency,
    # not necessarily the instrument currency. Preserve its actual FX impact.
    def trade_amount_and_rate(order, fill, instrument_ccy, gross_value)
      wallet = (fill[:walletImpact] || {}).with_indifferent_access
      net_value = (parse_decimal(wallet[:netValue]) || parse_decimal(order[:filledValue]))&.abs
      wallet_ccy = wallet[:currency].presence || order[:currency].presence || currency
      return [ gross_value, nil ] if net_value.nil? || net_value.zero?
      return [ net_value, nil ] if wallet_ccy == instrument_ccy
      return [ gross_value, nil ] if wallet_ccy != currency || gross_value.zero?

      [ gross_value, (net_value / gross_value).to_f ]
    end

    def process_split_cash(transaction, signed_amount)
      reference = transaction[:reference].to_s
      statement = (@trading212_account.statement_enrichments || {})[reference]
      type = transaction[:type].to_s.upcase
      label = INTEREST_TYPES.include?(type) ? "Interest" : (type == FEE_TYPE ? "Fee" : nil)
      name = label || I18n.t("trading212_split.unclassified_cash")
      cash_currency = transaction[:currency].presence || currency
      if statement
        raise Trading212Account::Snapshot::Invalid, "Statement amount or currency conflicts with API" unless
          statement["amount"].to_d == signed_amount && statement["currency"] == cash_currency
        raise Trading212Account::Snapshot::Invalid, "Statement type conflicts with API" unless statement["api_type"] == type
        name = statement["name"]
        label = statement["activity_label"]
      end

      merchant = statement&.dig("merchant").presence && account.family.merchants.find_or_create_by!(name: statement["merchant"])
      category = statement&.dig("category").presence && Trading212Statement.category_for(account.family, statement["category"])
      existing_entry = account.entries.find_by(source: "trading212", external_id: "trading212_transaction_#{reference}")
      if existing_entry && !existing_entry.transaction?
        raise Trading212Account::Snapshot::Invalid, "Cash reference collides with another entry type"
      end
      if existing_entry&.transaction&.transfer && !(statement && %w[Deposit Withdrawal].include?(statement["action"]))
        raise Trading212Account::Snapshot::Invalid, "Non-funding cash movement is linked to a transfer; review required"
      end
      classification_pending = statement.nil? && [ DEPOSIT_TYPE, WITHDRAW_TYPE ].include?(type)
      kind = classification_pending ? "unclassified" : "standard"
      kind = "funds_movement" if statement && %w[Deposit Withdrawal].include?(statement["action"])
      kind = existing_entry.transaction.kind if existing_entry&.transaction&.transfer
      kind = existing_entry.transaction.kind if existing_entry&.transaction&.locked?(:kind)
      entry = import_adapter.import_transaction(
        external_id: "trading212_transaction_#{reference}", amount: signed_amount,
        currency: cash_currency, date: parse_date(transaction[:dateTime]) || raise(ArgumentError, "Invalid cash transaction date"),
        name: name, source: "trading212", investment_activity_label: label,
        category_id: category&.id, merchant: merchant, kind: kind, allow_heuristic_matching: false,
        extra: { trading212: { reference: reference, type: type, amount: transaction[:amount],
          classification_pending: classification_pending }, trading212_statement: statement }.compact
      )
      Trading212Account::CashbackAllocation.new(@trading212_account).process(entry)
      true
    end

    # Earlier syncs stored every DEPOSIT as an investment contribution with the
    # Contribution label and category, and a matched bank leg as an investment
    # contribution too, so each top-up counted as spending (twice once matched).
    # The import now stores the deposit as a funds movement; clear the stale
    # label and category the user and Rules left alone, and fix the bank leg.
    def reset_legacy_contribution!(entry)
      transaction = entry&.entryable
      return unless transaction.is_a?(Transaction)
      return if entry.protected_from_sync?

      clear_contribution_attributes!(transaction)
      transfer = transaction.transfer
      reset_bank_leg!(transfer.outflow_transaction) if transfer && transfer.inflow_transaction_id == transaction.id
    end

    def reset_bank_leg!(outflow)
      return unless outflow&.investment_contribution?
      return if outflow.entry.protected_from_sync? || outflow.locked?(:kind) || rule_assigned?(outflow, :kind)

      outflow.update!(kind: "funds_movement")
      clear_contribution_attributes!(outflow)
    end

    def clear_contribution_attributes!(transaction)
      attrs = {}
      if transaction.investment_activity_label == "Contribution" && !transaction.locked?(:investment_activity_label) &&
          !rule_assigned?(transaction, :investment_activity_label)
        attrs[:investment_activity_label] = nil
      end
      if investment_contribution_category_ids.include?(transaction.category_id) && !transaction.locked?(:category_id) &&
          !rule_assigned?(transaction, :category_id)
        attrs[:category_id] = nil
      end
      transaction.update!(attrs) if attrs.any?
    end

    def rule_assigned?(transaction, attribute)
      transaction.data_enrichments.exists?(attribute_name: attribute.to_s, source: "rule")
    end

    def investment_contribution_category_ids
      @investment_contribution_category_ids ||= account.family.categories
        .where(name: Category.all_investment_contributions_names)
        .pluck(:id)
    end

    def build_order_name(ticker, signed_quantity)
      action = signed_quantity.negative? ? "Sell" : "Buy"
      "#{action} #{signed_quantity.abs} shares of #{ticker}"
    end

    def build_dividend_name(security)
      security ? "Dividend from #{security.ticker}" : "Dividend"
    end
end
