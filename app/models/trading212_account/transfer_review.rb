# Operators supply an explicitly reviewed entry ID and exact provider reference.
# This is intentionally not fuzzy matching and is never called by ordinary sync.
class Trading212Account::TransferReview
  Conflict = Class.new(StandardError)

  def initialize(provider_account, legacy_account:, user:)
    @provider = provider_account
    @legacy = legacy_account
    @user = user
  end

  def reattach!(transfer_id:, legacy_entry_id:, reference:)
    @provider.with_connection_lock do
      @provider.with_lock do
        cash = authorize!
        transfer = Transfer.find(transfer_id)
        transfer.with_lock do
          legacy_entry = @legacy.entries.transactions.find(legacy_entry_id)
          raise Conflict, "Selected entry is not a leg of this transfer" unless
            [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ].include?(legacy_entry.entryable_id)
          target = cash.entries.find_by!(source: "trading212", external_id: "trading212_transaction_#{reference}")
          raise Conflict, "Target is not a cash transaction" unless target.transaction?
          raise Conflict, "Target amount or currency differs from reviewed leg" unless target.amount == legacy_entry.amount && target.currency == legacy_entry.currency
          action = target.transaction.extra.dig("trading212_statement", "action")
          raise Conflict, "Only statement-confirmed funding can be reattached" unless %w[Deposit Withdrawal].include?(action)
          raise Conflict, "Target already has a transfer" if target.transaction.transfer
          raise Conflict, "Target was edited; manual review required" if target.protected_from_sync?
          original = transfer.attributes
          was_inflow = transfer.inflow_transaction_id == legacy_entry.entryable_id
          counterpart = was_inflow ? transfer.outflow_transaction : transfer.inflow_transaction
          raise Conflict, "Counterpart owner differs; review separately" unless counterpart.entry.account.owner_id == cash.owner_id
          raise Conflict, "Counterpart is not writable by this user" unless Account.writable_by(@user).exists?(id: counterpart.entry.account_id)
          raise Conflict, "Counterpart was edited; manual review required" if counterpart.entry.protected_from_sync?
          if [ target.transaction, counterpart ].any? { |transaction| transaction.locked?(:kind) }
            raise Conflict, "Transfer classification was locked; manual review required"
          end

          transfer.update!(was_inflow ? { inflow_transaction: target.transaction } : { outflow_transaction: target.transaction })
          # Preserve status, counterpart identity and its category. The legacy
          # representation loses its transfer kind; the new leg gets the proper
          # destination-derived kind without mutating unrelated accounts.
          legacy_entry.transaction.update!(kind: "standard")
          transfer.inflow_transaction.update!(kind: "funds_movement")
          transfer.outflow_transaction.update!(kind: Transfer.kind_for_account(transfer.to_account))
          audit = @provider.split_audit_payload.deep_dup
          reviews = audit.fetch("transfer_reviews", [])
          reviews << { "performed_at" => Time.current.iso8601, "user_id" => @user.id,
            "before" => original, "after" => transfer.attributes, "legacy_entry_id" => legacy_entry.id,
            "canonical_entry_id" => target.id, "reference" => reference }
          @provider.update!(split_audit_payload: audit.merge("transfer_reviews" => reviews))
          transfer
        end
      end
    end
  end

  private

    def authorize!
      cash = @provider.cash? ? @provider.current_account : @provider.sibling("cash")&.current_account
      raise Conflict, "Cash sibling required" unless cash
      raise Conflict, "Duplicate must be same family and owner" unless @legacy.family_id == cash.family_id && @legacy.owner_id == cash.owner_id
      raise Conflict, "Both accounts must be writable" unless @user.family_id == cash.family_id &&
        Account.writable_by(@user).where(id: [ cash.id, @legacy.id ]).count == 2
      raise Conflict, "Wait for provider synchronization" if @provider.trading212_item.syncs.visible.exists?
      cash
    end
end
