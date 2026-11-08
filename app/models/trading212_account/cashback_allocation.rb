# An explicit allocation of a posted reward to Pie cash, not another reward or
# an ETF purchase. No date-wide/ticker-wide rule is inferred from today's setup.
class Trading212Account::CashbackAllocation
  def initialize(cash_provider)
    @provider = cash_provider
  end

  def review!(reference:, evidence:, actor:)
    @provider.with_connection_lock do
      @provider.with_lock do
        portfolio = @provider.sibling("portfolio")
        accounts = [ @provider.current_account, portfolio&.current_account ].compact
        unless @provider.cash? && accounts.size == 2 && accounts.map(&:owner_id).uniq.size == 1 &&
            accounts.all? { |account| account.family_id == @provider.trading212_item.family_id } &&
            actor.family_id == @provider.trading212_item.family_id && Account.writable_by(actor).where(id: accounts.map(&:id)).count == 2
          raise ActiveRecord::RecordNotFound
        end
        raise ArgumentError, "Funding evidence is required" if evidence.blank?
        raise ArgumentError, "Wait for provider synchronization" if @provider.trading212_item.syncs.visible.exists?
        statement = @provider.statement_enrichments[reference.to_s]
        unless statement && statement["action"] == "Spending cashback" && statement["amount"].to_d.finite? && statement["amount"].to_d.negative?
          raise ArgumentError, "Select an exact positive statement-confirmed cashback credit; reversals require separate review"
        end
        rows = @provider.activity_payload(:raw_transactions_payload).select { |row| row["reference"].to_s == reference.to_s }
        unless rows.one? && rows.sole["type"] == "DEPOSIT" && rows.sole["amount"].to_d.abs == -statement["amount"].to_d &&
            (rows.sole["currency"].presence || @provider.currency) == statement["currency"] && statement["currency"] == @provider.currency
          raise ArgumentError, "Cashback statement conflicts with API"
        end
        audit = @provider.split_audit_payload.deep_dup
        allocations = audit.fetch("cashback_allocations", {})
        timestamp = Time.iso8601(rows.sole.fetch("dateTime"))
        allocation = { "amount" => -statement["amount"].to_d, "currency" => statement["currency"], "posted_timestamp" => timestamp.iso8601 }.as_json
        previous = allocations[reference.to_s]
        if previous && previous.slice("amount", "currency", "posted_timestamp") != allocation
          raise ArgumentError, "Cashback allocation changed; migration review required"
        end
        return previous if previous

        allocations[reference.to_s] = allocation.merge("evidence" => evidence, "actor_id" => actor.id, "reviewed_at" => Time.current.iso8601)
        @provider.update!(split_audit_payload: audit.merge("cashback_allocations" => allocations))
        allocations[reference.to_s]
      end
    end
  end

  def process(entry)
    unless entry.account_id == @provider.current_account&.id && entry.source == "trading212" && entry.transaction?
      raise Trading212Account::Snapshot::Invalid, "Cashback entry belongs to another ledger"
    end
    allocation = @provider.split_audit_payload.dig("cashback_allocations", entry.external_id.delete_prefix("trading212_transaction_"))
    return unless allocation

    ApplicationRecord.transaction do
      portfolio = @provider.sibling("portfolio")&.usable_account
      raise Trading212Account::Snapshot::Invalid, "Active portfolio required for cashback allocation" unless portfolio && @provider.usable_account
      unless portfolio.family_id == entry.account.family_id && portfolio.owner_id == entry.account.owner_id && portfolio.currency == entry.currency
        raise Trading212Account::Snapshot::Invalid, "Cashback siblings have incompatible ownership or currency"
      end
      statement = entry.transaction.extra["trading212_statement"]
      unless allocation["evidence"].present? && statement && statement["action"] == "Spending cashback" && entry.amount.negative? &&
          -entry.amount == allocation["amount"].to_d && entry.currency == allocation["currency"] &&
          Time.iso8601(allocation.fetch("posted_timestamp")).in_time_zone.to_date == entry.date
        raise Trading212Account::Snapshot::Invalid, "Reviewed cashback allocation conflicts with posted reward"
      end
      legs = [ [ @provider.current_account, -entry.amount, "out" ], [ portfolio, entry.amount, "in" ] ]
      legs.each do |account, amount, direction|
        existing = account.entries.find_by(source: "trading212", external_id: "trading212_cashback_#{direction}_#{entry.external_id}")
        if existing && (!existing.transaction? || existing.protected_from_sync? ||
            %i[amount currency date].any? { |attribute| existing.locked?(attribute) } || existing.transaction.locked?(:kind) ||
            existing.amount != amount || existing.currency != entry.currency || existing.date != entry.date)
          raise Trading212Account::Snapshot::Invalid, "Cashback allocation changed or protected; review required"
        end
      end
      outflow, inflow = legs.map do |account, amount, direction|
        Account::ProviderImportAdapter.new(account).import_transaction(
          external_id: "trading212_cashback_#{direction}_#{entry.external_id}", amount: amount, currency: entry.currency,
          date: entry.date, name: I18n.t("trading212_split.cashback_allocation"), source: "trading212", kind: "funds_movement",
          investment_activity_label: "Transfer", allow_heuristic_matching: false,
          extra: { trading212: { cashback_allocation_for: entry.external_id, review: allocation.slice("actor_id", "reviewed_at") } }
        ).transaction
      end
      existing = inflow.transfer || outflow.transfer
      if existing
        unless existing.inflow_transaction_id == inflow.id && existing.outflow_transaction_id == outflow.id && existing.valid?
          raise Trading212Account::Snapshot::Invalid, "Cashback allocation is linked to another movement"
        end
      elsif RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)
        raise Trading212Account::Snapshot::Invalid, "Cashback allocation was rejected; review required"
      else
        Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")
      end
    end
  end
end
