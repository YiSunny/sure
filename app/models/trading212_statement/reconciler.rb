class Trading212Statement::Reconciler
  CATEGORY_MAP = {
    "RESTAURANTS" => "Dining Out", "AUTOMOBILE_RENTAL" => "Transportation",
    "TRANSPORT" => "Transportation", "CLOTHING_STORES" => "Shopping",
    "HOTELS" => "Travel", "AIRLINES" => "Travel"
  }.freeze

  def initialize(statement)
    @statement = statement
    @provider_account = statement.trading212_account
  end

  def preview
    raise ArgumentError, "Statement enrichment requires a combined or Cash account" unless @provider_account.combined? || @provider_account.cash?
    matched = []
    conflicts = []
    skipped = []
    seen = Set.new
    payload = @provider_account.activity_payload(:raw_transactions_payload).group_by { |r| r["reference"].to_s }
    @statement.rows.each do |row|
      action = row.fetch("action")
      if Trading212Statement::Parser::TRADE_ACTIONS.include?(action) || action.start_with?("Dividend")
        skipped << { row: row["row"], reason: "api_owned_trade_or_dividend" }
        next
      end
      reason = if row["reference"].blank?
        "missing_reference"
      elsif !seen.add?(row["reference"])
        "duplicate_reference"
      elsif !Trading212Statement::Parser::CASH_ACTIONS.include?(action)
        "unsupported_action"
      elsif !(candidates = payload[row["reference"]])
        "reference_not_found_in_selected_account"
      elsif candidates.size != 1
        "ambiguous_api_reference"
      else
        reconcile(row, candidates.first)
      end
      if reason.is_a?(Hash)
        matched << reason
      else
        conflicts << { row: row["row"], reason: reason }
      end
    end
    dates = matched.map { |row| row["purchase_timestamp"][0, 10] }
    { matched: matched, conflicts: conflicts, skipped: skipped, coverage_start: dates.min, coverage_end: dates.max }
  end

  def apply_entries!(rows)
    rows.each do |row|
      entry = cash.entries.find_by(source: "trading212", external_id: "trading212_transaction_#{row['reference']}")
      next unless entry
      raise ArgumentError, "Protected entry requires manual review" if entry.protected_from_sync?
      funding = %w[Deposit Withdrawal].include?(row["action"])
      raise ArgumentError, "Existing transfer requires manual review" if entry.transaction.transfer && !funding
      transaction = entry.transaction
      before = { "entry" => entry.attributes.slice("name", "notes", "date", "amount", "currency"),
        "transaction" => transaction.attributes.slice("kind", "investment_activity_label", "category_id", "merchant_id", "extra") }
      kind = funding ? "funds_movement" : "standard"
      transaction.enrich_attributes({ kind: transaction.transfer ? transaction.kind : kind, investment_activity_label: row["activity_label"] }, source: "trading212")
      entry.enrich_attribute(:name, row["name"], source: "trading212")
      if row["category"].present? && transaction.category_id.nil?
        transaction.enrich_attribute(:category_id, Trading212Statement.category_for(cash.family, row["category"]).id, source: "trading212")
      end
      if row["merchant"].present? && transaction.merchant_id.nil?
        transaction.enrich_attribute(:merchant_id, cash.family.merchants.find_or_create_by!(name: row["merchant"]).id, source: "trading212")
      end
      transaction.update!(extra: transaction.extra.deep_merge("trading212_statement" => row,
        "trading212" => { "classification_pending" => false }))
      # Save before-values per batch for a reviewed reversal; don't rely on the
      # next provider sync to reconstruct previous classification or provenance.
      changes = (@statement.result["before_values"] || {}).merge(entry.id => before)
      after = { "entry" => entry.reload.attributes.slice("name", "notes", "date", "amount", "currency"),
        "transaction" => transaction.reload.attributes.slice("kind", "investment_activity_label", "category_id", "merchant_id", "extra") }
      @statement.result = @statement.result.merge("before_values" => changes,
        "after_values" => (@statement.result["after_values"] || {}).merge(entry.id => after))
    end
  end

  private

    def cash
      @provider_account.current_account
    end

    def reconcile(row, api)
      action = row["action"]
      amount = -BigDecimal(row["net"] || row["gross"])
      expected_type = case action
      when "Card debit", "Withdrawal" then "WITHDRAW"
      when "Card credit", "Spending cashback", "Deposit" then "DEPOSIT"
      when "Interest on cash" then "INTEREST_ON_FREE_CASH"
      when "Lending interest" then "LENDING_INTEREST"
      end
      # A clawed-back reward is exported as negative Spending cashback and
      # delivered by the API as WITHDRAW, not DEPOSIT. Keep the signed amount.
      expected_type = "WITHDRAW" if action == "Spending cashback" && amount.positive?
      return "api_type_conflict" unless api["type"] == expected_type
      return "currency_conflict" unless row["currency"] == (api["currency"].presence || @provider_account.currency)
      api_amount = BigDecimal(api["amount"].to_s).abs * (api["type"] == "WITHDRAW" ? 1 : -1)
      return "invalid_api_amount" unless api_amount.finite?
      return "amount_conflict" unless api_amount == amount
      return "direction_conflict" unless amount.nonzero? && (expected_type == "WITHDRAW" ? amount.positive? : amount.negative?)
      entry = cash&.entries&.find_by(source: "trading212", external_id: "trading212_transaction_#{row['reference']}")
      return "entry_type_conflict" if entry && !entry.transaction?
      return "protected_entry" if entry&.protected_from_sync?
      return "existing_transfer_requires_review" if entry&.transaction&.transfer && !%w[Deposit Withdrawal].include?(action)
      return "existing_entry_amount_or_currency_conflict" if entry && (entry.amount != amount || entry.currency != row["currency"])
      return "split_entry_requires_review" if entry && (entry.split_parent? || entry.split_child?)
      return "locked_classification_requires_review" if entry && (entry.locked?(:name) ||
        %i[kind investment_activity_label].any? { |attribute| entry.transaction.locked?(attribute) })
      previous = (@provider_account.statement_enrichments || {})[row["reference"]]
      return "previous_statement_conflict" if previous && previous.slice("action", "gross", "net", "currency", "merchant", "provider_category") != row.slice("action", "gross", "net", "currency", "merchant", "provider_category")

      label = action.in?([ "Interest on cash", "Lending interest" ]) ? "Interest" : nil
      category = case action
      when "Interest on cash", "Lending interest" then "Interest"
      when "Spending cashback" then "Cashback"
      else CATEGORY_MAP[row["provider_category"]]
      end
      row.merge("amount" => amount.to_s("F"), "activity_label" => label,
        "name" => row["merchant"].presence || action, "category" => category,
        "api_type" => api["type"], "posted_timestamp" => api["dateTime"],
        "statement_checksum" => @statement.checksum, "state" => entry ? "enrich_existing" : "enrich_on_next_sync")
    rescue ArgumentError
      "invalid_api_amount"
    end
end
