class Trading212Account::Settlement
  def initialize(portfolio)
    @portfolio = portfolio
  end

  def process(trade_entry, fill)
    ApplicationRecord.transaction { process_settlement(trade_entry, fill.with_indifferent_access) }
  end

  # Operator-only: record independently checked funding evidence. Does not
  # create entries, run sync, or rewrite an already booked allocation.
  def review!(reference:, cash_amount:, evidence:, actor:, funding_type: "cash_and_pie")
    @portfolio.with_connection_lock do
      @portfolio.with_lock do
        cash = @portfolio.sibling("cash")&.current_account
        accounts = [ @portfolio.current_account, cash ].compact
        unless @portfolio.portfolio? && accounts.size == 2 && accounts.map(&:owner_id).uniq.size == 1 &&
            accounts.all? { |account| account.family_id == @portfolio.trading212_item.family_id } &&
            actor.family_id == @portfolio.trading212_item.family_id && Account.writable_by(actor).where(id: accounts.map(&:id)).count == 2
          raise ActiveRecord::RecordNotFound
        end
        raise Trading212Account::Snapshot::Invalid, "Wait for provider synchronization" if @portfolio.trading212_item.syncs.visible.exists?
        raise ArgumentError, "Funding evidence is required" if evidence.blank?
        raise ArgumentError, "Unsupported funding type" unless %w[cash_and_pie referral_reward].include?(funding_type)
        rows = Array(@portfolio.raw_orders_payload).select { |row| (row.dig("fill", "id") || row.dig("order", "id")).to_s == reference.to_s && row.dig("order", "status") == "FILLED" }
        raise ArgumentError, "Select one exact filled trade" unless rows.one?
        wallet = rows.sole.dig("fill", "walletImpact") || {}
        wallet_amount = decimal(wallet["netValue"]).abs
        amount = decimal(cash_amount)
        unless amount.finite? && wallet_amount.finite? && wallet_amount.positive? && amount >= 0 && amount <= wallet_amount && wallet["currency"] == cash.currency
          raise ArgumentError, "Invalid funding allocation"
        end
        if funding_type == "referral_reward" && (rows.sole.dig("order", "side") != "BUY" || !amount.zero?)
          raise ArgumentError, "Referral reward must be a buy funded without account cash"
        end
        allocations = @portfolio.settlement_allocations.deep_dup
        previous = allocations[reference.to_s]
        if previous && (previous["cash_amount"].to_d != amount || previous["wallet_amount"].to_d != wallet_amount || previous["currency"] != wallet["currency"] ||
            previous.fetch("funding_type", "cash_and_pie") != funding_type)
          raise Trading212Account::Snapshot::Invalid, "Existing allocation requires explicit migration review"
        end
        return previous if previous

        allocations[reference.to_s] = { "cash_amount" => amount.to_s("F"), "wallet_amount" => wallet_amount.to_s("F"),
          "currency" => wallet["currency"], "funding_type" => funding_type, "evidence" => evidence, "actor_id" => actor.id, "reviewed_at" => Time.current.iso8601 }
        @portfolio.update!(settlement_allocations: allocations)
        allocations[reference.to_s]
      end
    end
  end

  private

    def process_settlement(trade_entry, fill)
      cash = @portfolio.sibling("cash")&.usable_account
      raise Trading212Account::Snapshot::Invalid, "Both cash and portfolio accounts must be active for settlement" unless cash

      wallet = (fill[:walletImpact] || {}).with_indifferent_access
      wallet_amount = decimal(wallet[:netValue]).abs
      wallet_currency = wallet[:currency]
      raise Trading212Account::Snapshot::Invalid, "Settlement currency differs from account" unless wallet_currency == cash.currency
      raise Trading212Account::Snapshot::Invalid, "Settlement amount must be finite and positive" unless wallet_amount.finite? && wallet_amount.positive?

      reference = trade_entry.external_id.delete_prefix("trading212_order_")
      # Neither AUTOINVEST nor walletImpact identifies the funding pot. A reviewed
      # allocation records only the amount crossing Cash/Portfolio; the remainder
      # consumes (or replenishes) cash already allocated inside the portfolio.
      allocation = (@portfolio.settlement_allocations || {})[reference]
      unless allocation && allocation["evidence"].present? && allocation["currency"] == wallet_currency
        raise Trading212Account::Snapshot::Invalid, I18n.t("trading212_split.unresolved_settlement")
      end
      cash_amount = decimal(allocation["cash_amount"])
      unless decimal(allocation["wallet_amount"]) == wallet_amount
        raise Trading212Account::Snapshot::Invalid, "Settlement wallet amount changed; review allocation again"
      end
      unless cash_amount.finite? && cash_amount >= 0 && cash_amount <= wallet_amount
        raise Trading212Account::Snapshot::Invalid, "Invalid reviewed settlement allocation"
      end
      funding_type = allocation.fetch("funding_type", "cash_and_pie")
      raise Trading212Account::Snapshot::Invalid, "Unsupported reviewed funding type" unless %w[cash_and_pie referral_reward].include?(funding_type)
      if funding_type == "referral_reward" && (!cash_amount.zero? || !trade_entry.trade.qty.positive?)
        raise Trading212Account::Snapshot::Invalid, "Invalid referral reward allocation"
      end
      previous_type = trade_entry.trade.extra.dig("trading212", "funding_type")
      if previous_type && previous_type != funding_type
        raise Trading212Account::Snapshot::Invalid, "Trade funding classification changed; migration review required"
      end
      trade_entry.trade.update!(extra: trade_entry.trade.extra.deep_merge("trading212" => { "funding_type" => funding_type }))
      if cash_amount.zero?
        existing = [ cash, @portfolio.current_account ].any? do |account|
          account.entries.where(source: "trading212", external_id: [ "trading212_settlement_#{reference}", "trading212_counterpart_#{reference}" ]).exists?
        end
        raise Trading212Account::Snapshot::Invalid, "Existing settlement requires explicit migration review" if existing
        process_referral_reward(trade_entry, wallet_amount, wallet_currency, reference, allocation) if funding_type == "referral_reward"
        return
      end

      signed_cash = trade_entry.amount.positive? ? cash_amount : -cash_amount
      counterpart_amount = -trade_entry.amount * cash_amount / wallet_amount
      metadata = { trading212: { settlement_for: trade_entry.external_id,
        allocation: allocation.slice("cash_amount", "wallet_amount", "currency", "actor_id", "reviewed_at") } }
      [ [ cash, "trading212_settlement_#{reference}" ], [ @portfolio.current_account, "trading212_counterpart_#{reference}" ] ].each do |account, external_id|
        existing = account.entries.find_by(source: "trading212", external_id: external_id)
        raise Trading212Account::Snapshot::Invalid, "Settlement reference collides with another entry type" if existing && !existing.transaction?
        raise Trading212Account::Snapshot::Invalid, "Protected settlement requires manual review" if existing&.protected_from_sync?
        if existing && (%i[amount currency date].any? { |attribute| existing.locked?(attribute) } || existing.transaction.locked?(:kind))
          raise Trading212Account::Snapshot::Invalid, "Locked settlement requires manual review"
        end
        expected_amount, expected_currency = account == cash ? [ signed_cash, wallet_currency ] : [ counterpart_amount.round(4), trade_entry.currency ]
        if existing && (existing.amount != expected_amount || existing.currency != expected_currency || existing.date != trade_entry.date)
          raise Trading212Account::Snapshot::Invalid, "Existing settlement changed; explicit migration review required"
        end
      end
      cash_entry = Account::ProviderImportAdapter.new(cash).import_transaction(
        external_id: "trading212_settlement_#{reference}", amount: signed_cash, currency: wallet_currency,
        date: trade_entry.date, name: trade_entry.name, source: "trading212", kind: "funds_movement",
        investment_activity_label: "Transfer", allow_heuristic_matching: false, extra: metadata
      )
      # Offset only the Cash-funded portion in the Trade's own currency. Use
      # the same provider FX rate, not independently converted market rates.
      counterpart = Account::ProviderImportAdapter.new(@portfolio.current_account).import_transaction(
        external_id: "trading212_counterpart_#{reference}", amount: counterpart_amount, currency: trade_entry.currency,
        date: trade_entry.date, name: I18n.t("trading212_split.settlement"), source: "trading212", kind: "funds_movement",
        investment_activity_label: "Transfer", allow_heuristic_matching: false, extra: metadata
      )
      counterpart.entryable.update!(exchange_rate: trade_entry.entryable.exchange_rate)
      inflow, outflow = signed_cash.positive? ? [ counterpart.entryable, cash_entry.entryable ] : [ cash_entry.entryable, counterpart.entryable ]
      if inflow.transfer || outflow.transfer
        existing = inflow.transfer || outflow.transfer
        raise Trading212Account::Snapshot::Invalid, "Settlement linked to another movement; review required" unless
          existing.inflow_transaction_id == inflow.id && existing.outflow_transaction_id == outflow.id
        raise Trading212Account::Snapshot::Invalid, "Settlement amounts changed incompatibly" unless existing.valid?
        return
      end
      return if RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)

      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")
    end

    def process_referral_reward(trade_entry, wallet_amount, wallet_currency, reference, allocation)
      # The provider represents a free-share award as a BUY. Preserve that trade,
      # offset its cash cost with reward income in Portfolio, never a Cash debit.
      # It is a referral benefit, not a dividend or the owner's contribution.
      account = @portfolio.current_account
      external_id = "trading212_referral_reward_#{reference}"
      existing = account.entries.find_by(source: "trading212", external_id: external_id)
      if existing && (!existing.transaction? || existing.protected_from_sync? ||
          %i[amount currency date].any? { |attribute| existing.locked?(attribute) } ||
          %i[kind category_id investment_activity_label].any? { |attribute| existing.transaction.locked?(attribute) } ||
          existing.transaction.transfer || existing.amount != -wallet_amount || existing.currency != wallet_currency || existing.date != trade_entry.date)
        raise Trading212Account::Snapshot::Invalid, "Referral reward changed or protected; review required"
      end
      Account::ProviderImportAdapter.new(account).import_transaction(
        external_id: external_id, amount: -wallet_amount, currency: wallet_currency,
        date: trade_entry.date, name: I18n.t("trading212_split.referral_reward"), source: "trading212", kind: "standard",
        category_id: Trading212Statement.category_for(account.family, I18n.t("trading212_split.referral_reward")).id,
        investment_activity_label: "Other", allow_heuristic_matching: false,
        extra: { security_id: trade_entry.trade.security_id,
          trading212: { reward_for: trade_entry.external_id, funding_type: "referral_reward",
            review: allocation.slice("actor_id", "reviewed_at") } }
      )
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      raise Trading212Account::Snapshot::Invalid, "Missing or invalid settlement amount"
    end
end
