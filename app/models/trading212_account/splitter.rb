class Trading212Account::Splitter
  Conflict = Class.new(StandardError)

  def initialize(provider_account, user:)
    @provider_account = provider_account
    @user = user
  end

  def preview
    authorize!
    snapshot = @provider_account.snapshot.validate!
    { total: snapshot.total, cash: snapshot.cash, investments: snapshot.investments,
      available_to_trade: snapshot.available_to_trade, cash_in_pies: snapshot.cash_in_pies,
      currency: snapshot.currency, fetched_at: @provider_account.last_positions_sync,
      stale: @provider_account.last_positions_sync.nil? || @provider_account.last_positions_sync < 24.hours.ago,
      cash_entries: cash_entries.count,
      transfers_to_review: cash_entries.joins("INNER JOIN transfers ON transfers.inflow_transaction_id = entries.entryable_id OR transfers.outflow_transaction_id = entries.entryable_id").count }
  end

  def apply!
    @provider_account.with_connection_lock { apply_under_connection_lock! }
  end

  private

    def apply_under_connection_lock!
      result = nil
      @provider_account.with_lock do
        # The item lock is acquired before this provider lock. No automatic sync
        # is started by this command.
        authorize!
        return @provider_account.sibling("cash") if @provider_account.portfolio?
        raise Conflict, "Only a combined investment account can be split" unless @provider_account.combined? && account.investment?
        summary = preview
        raise Conflict, I18n.t("trading212_split.stale_split") if summary[:stale]
        raise Conflict, "Review and resolve transfers involving legacy cash entries before splitting" if summary[:transfers_to_review].positive?
        raise Conflict, "Account currency differs from summary" unless account.currency == summary[:currency]
        if cash_entries.where.not(parent_entry_id: nil).exists? || cash_entries.joins(:child_entries).exists?
          raise Conflict, "Split cash transactions need manual migration review"
        end
        raise Conflict, "Account has non-provider cash entries; review them before splitting" if account.entries.transactions
          .where.not(id: cash_entries.select(:id)).exists?
        audit = { "performed_at" => Time.current.iso8601, "user_id" => @user.id,
          "account" => account.attributes, "cash_entries" => cash_entries.includes(:entryable).map { |entry|
            { "entry" => entry.attributes, "transaction" => entry.entryable.attributes }
          }, "valuations" => account.entries.valuations.includes(:entryable).map { |entry|
            { "entry" => entry.attributes, "valuation" => entry.entryable.attributes }
          } }

        cash_provider = @provider_account.trading212_item.trading212_accounts.create!(
          kind: "cash", trading212_account_id: @provider_account.trading212_account_id,
          name: I18n.t("trading212_split.cash_name", name: account.name), currency: account.currency,
          raw_summary_payload: @provider_account.raw_summary_payload,
          current_balance: summary[:cash], cash_balance: summary[:cash]
        )
        cash = account.family.accounts.create!(
          name: cash_provider.name, currency: account.currency, balance: summary[:cash], cash_balance: summary[:cash],
          accountable: Depository.new(subtype: "checking"), owner: account.owner,
          status: account.status, disabled_at: account.disabled_at, exclude_from_reports: account.exclude_from_reports
        )
        # Sharing is copied exactly, not re-inferred from the requesting admin.
        cash.account_shares.destroy_all
        account.account_shares.each do |share|
          cash.account_shares.create!(user_id: share.user_id, permission: share.permission, include_in_finances: share.include_in_finances)
        end
        cash_provider.ensure_account_provider!(cash) || raise(Conflict, "Cash provider link failed")

        cash_entries.includes(:entryable).each do |entry|
          transaction = entry.entryable
          legacy_funding = %w[Contribution Withdrawal].include?(transaction.investment_activity_label) ||
            %w[DEPOSIT WITHDRAW].include?(transaction.extra.dig("trading212", "type"))
          if !entry.protected_from_sync? && legacy_funding &&
              %i[kind investment_activity_label category_id].any? { |attribute| transaction.locked?(attribute) }
            raise Conflict, "Legacy activity has locked classifications; review before splitting"
          end
          if !entry.protected_from_sync? && legacy_funding
            attributes = { investment_activity_label: nil, kind: "unclassified" }
            attributes[:category_id] = nil if transaction.category&.name.in?(Category.all_investment_contributions_names)
            transaction.enrich_attributes(attributes, source: "trading212")
            transaction.update!(extra: transaction.extra.deep_merge("trading212" => { "classification_pending" => true }))
          end
          entry.update!(account: cash)
        end
        @provider_account.reload
        # Preserve exact prior anchors before retiring combined-account values.
        # Merely excluding a valuation does not remove it from balance calculations.
        @provider_account.update!(split_audit_payload: audit)
        account.entries.valuations.destroy_all
        account.balances.delete_all
        @provider_account.update!(kind: "portfolio")
        account.update!(name: I18n.t("trading212_split.portfolio_name", name: account.name),
          balance: summary[:investments], cash_balance: summary[:cash_in_pies])
        [ [ account, summary[:investments] ], [ cash, summary[:cash] ] ].each do |target, balance|
          result = target.set_current_balance(balance, schedule_sync: false)
          raise Conflict, result.error unless result.success?
        end
        # No historical zero opening is invented. Existing trades and moved cash
        # history are retained; coverage must be reconciled before enabling sync.
        result = cash_provider
      end
      result
    end

    def account
      @provider_account.current_account || raise(Conflict, "Link an investment account first")
    end

    def authorize!
      raise Conflict, "Account is not writable by this user" unless @user.family_id == account.family_id &&
        Account.writable_by(@user).exists?(id: account.id)
      raise Conflict, "Wait for the current provider sync to finish" if @provider_account.trading212_item.syncs.visible.exists?
    end

    def cash_entries
      account.entries.where(source: "trading212", entryable_type: "Transaction")
        .where("entries.external_id LIKE 'trading212_transaction_%' OR entries.external_id LIKE 'trading212_dividend_%'")
    end
end
