class Trading212Account::Snapshot
  Invalid = Class.new(StandardError)
  TOLERANCE = BigDecimal("0.02")
  POSITION_QUOTE_TOLERANCE = BigDecimal("0.001")

  def initialize(payload)
    @payload = payload.with_indifferent_access
  end

  def total
    number(@payload[:totalValue])
  end

  def cash
    # Spending Pot cash is absent from the documented cash fields. Derive the
    # non-portfolio balance from the same summary, not by adding cash buckets
    # whose overlap/portfolio inclusion is not specified by Trading 212.
    total - investments
  end

  def available_to_trade
    number(@payload.dig(:cash, :availableToTrade))
  end

  def cash_in_pies
    number(@payload.dig(:cash, :inPies))
  end

  def reserved_for_orders
    number(@payload.dig(:cash, :reservedForOrders))
  end

  def investments
    number(@payload.dig(:investments, :currentValue))
  end

  def currency
    @payload[:currency].presence || raise(Invalid, "Account summary currency is missing")
  end

  def validate!
    raise Invalid, "Negative account summary component" if cash.negative? || investments.negative?
    raise Invalid, "Available cash exceeds total non-portfolio cash" if available_to_trade - cash > TOLERANCE
    raise Invalid, "Negative account summary cash bucket" if [ cash_in_pies, reserved_for_orders, available_to_trade ].any?(&:negative?)
    raise Invalid, "Pie cash exceeds portfolio value" if cash_in_pies > investments
    Money::Currency.new(currency)
    self
  end

  def validate_positions!(positions)
    value = positions.sum do |position|
      wallet = position.fetch("walletImpact", {})
      raise Invalid, "Position wallet currency differs from summary" unless wallet["currency"] == currency
      number(wallet["currentValue"])
    end
    # Summary and positions are separate HTTP requests, not an atomic quote.
    # Allow 0.1% quote movement (at least five cents), but reject missing/large
    # partial snapshots. The summary remains the balance anchor either way.
    tolerance = [ BigDecimal("0.05"), investments * POSITION_QUOTE_TOLERANCE ].max
    raise Invalid, "Position values and Pie cash do not reconcile to portfolio" if (value + cash_in_pies - investments).abs > tolerance
    self
  end

  private

    def number(value)
      number = BigDecimal(value.to_s)
      raise Invalid, "Non-finite account summary amount" unless number.finite?
      number
    rescue ArgumentError, TypeError
      raise Invalid, "Incomplete account summary: all cash and investment components are required"
    end
end
