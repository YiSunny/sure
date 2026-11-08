# Explicitly archives a duplicate manual import without deleting its entries or
# pretending that its balance is verified. Never run automatically during sync.
class Trading212Account::LegacyArchive
  Conflict = Class.new(StandardError)

  def initialize(provider_account, legacy_account:, user:)
    @provider = provider_account
    @legacy = legacy_account
    @user = user
  end

  def preview
    authorize!
    { legacy_account_id: @legacy.id, transactions_preserved: @legacy.entries.transactions.count,
      pending_transfers_to_review: transfers.pending.count,
      confirmed_transfers_to_review: transfers.confirmed.count,
      experimental_balance: @legacy.balance, currency: @legacy.currency }
  end

  def apply!
    @provider.with_connection_lock { apply_under_connection_lock! }
  end

  private

    def apply_under_connection_lock!
      @provider.with_lock do
        @legacy.with_lock do
          authorize!
          return if @legacy.disabled? && @legacy.exclude_from_reports?
          raise Conflict, "Review all transfers involving the duplicate account before archiving" if transfers.exists?
          audit = @provider.split_audit_payload.deep_dup
          archives = audit.fetch("legacy_archives", {})
          archives[@legacy.id] = { "performed_at" => Time.current.iso8601, "user_id" => @user.id,
            "account" => @legacy.attributes, "entry_count" => @legacy.entries.count }
          @provider.update!(split_audit_payload: audit.merge("legacy_archives" => archives))
          # Report exclusion also removes the duplicate's historical net-worth
          # contribution; disabling alone would leave its old chart values active.
          @legacy.update!(status: "disabled", disabled_at: Time.current, exclude_from_reports: true)
        end
      end
    end

    def authorize!
      account = @provider.current_account
      raise Conflict, "Select the intended provider account" unless account && @provider.portfolio?
      raise Conflict, "Duplicate must be an unlinked manual account owned by the same person" unless
        @legacy.family_id == account.family_id && @legacy.owner_id == account.owner_id && @legacy.manual? && @legacy.depository?
      raise Conflict, "Account is not writable by this user" unless
        @user.family_id == account.family_id && Account.writable_by(@user).where(id: [ account.id, @legacy.id ]).count == 2
      raise Conflict, "Wait for the provider sync to finish" if @provider.trading212_item.syncs.visible.exists?
    end

    def transfers
      ids = @legacy.entries.transactions.select(:entryable_id)
      Transfer.where(inflow_transaction_id: ids).or(Transfer.where(outflow_transaction_id: ids))
    end
end
