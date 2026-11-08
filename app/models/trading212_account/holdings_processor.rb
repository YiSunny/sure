class Trading212Account::HoldingsProcessor
  include Trading212Account::DataHelpers

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    return unless account.present?

    positions = Array(@trading212_account.raw_positions_payload)
    @trading212_account.snapshot.validate_positions!(positions) if @trading212_account.portfolio?
    processed = positions.count do |position|
      process_position(position.with_indifferent_access).present?
    end
    if @trading212_account.portfolio?
      raise Trading212Account::Snapshot::Invalid, "Incomplete holdings snapshot" unless processed == positions.size
      ids = positions.map { |position| position.dig("instrument", "ticker") }.compact
      prefix = "trading212_position_#{@trading212_account.trading212_account_id}_"
      current_ids = ids.map { |ticker| "#{prefix}#{ticker}_#{Date.current}" }
      account.holdings.where(account_provider_id: @trading212_account.account_provider&.id, date: Date.current)
        .where.not(external_id: current_ids).destroy_all
    end
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

    def process_position(position)
      instrument = (position[:instrument] || {}).with_indifferent_access
      t212_ticker = instrument[:ticker].to_s
      return if t212_ticker.blank?

      isin         = instrument[:isin].presence
      ticker       = standard_ticker(t212_ticker)
      name         = instrument[:name].presence || ticker
      position_ccy = instrument[:currency].presence || currency

      security = resolve_security_direct(isin, ticker, name)
      return unless security

      quantity = parse_decimal(position[:quantity])
      price    = parse_decimal(position[:currentPrice])
      return unless quantity && price && quantity > 0
      position_ccy, price = normalize_minor_units(position_ccy, price)

      amount = quantity * price
      date   = Date.current

      external_id = "trading212_position_#{@trading212_account.trading212_account_id}_#{t212_ticker}_#{date}"

      holding = import_adapter.import_holding(
        security:           security,
        quantity:           quantity,
        amount:             amount,
        currency:           position_ccy,
        date:               date,
        price:              price,
        cost_basis:         normalize_minor_units(instrument[:currency].presence || currency, parse_decimal(position[:averagePricePaid])).last,
        external_id:        external_id,
        source:             "trading212",
        account_provider_id: @trading212_account.account_provider&.id,
        delete_future_holdings: false
      )
      if @trading212_account.portfolio?
        wallet = position.fetch(:walletImpact).with_indifferent_access
        value = parse_decimal(wallet[:currentValue])
        raise Trading212Account::Snapshot::Invalid, "Invalid position wallet value" unless value&.finite? && value >= 0 && wallet[:currency] == currency
        raise Trading212Account::Snapshot::Invalid, "Position belongs to another provider" unless holding.account_provider_id == @trading212_account.account_provider.id

        holding.update!(provider_value: value, provider_value_currency: wallet[:currency])
      end
      holding
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Trading212Account::HoldingsProcessor - Failed to process position #{t212_ticker}: #{e.message}",
        source: "trading212",
        family: @trading212_account.trading212_item.family,
        provider_key: "trading212",
        metadata: { ticker: t212_ticker, trading212_account_id: @trading212_account.id }
      )
      raise if @trading212_account.portfolio?
    end
end
