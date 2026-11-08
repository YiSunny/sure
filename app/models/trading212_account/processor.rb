class Trading212Account::Processor
  attr_reader :trading212_account

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    return unless account.present?
    return if account.disabled? || account.pending_deletion?

    trading212_account.with_lock do
      update_account_balance!
      Trading212Account::HoldingsProcessor.new(trading212_account).process unless trading212_account.cash?
      Trading212Account::ActivitiesProcessor.new(trading212_account).process
      trading212_account.update!(last_processed_at: Time.current)
    end

    account.broadcast_sync_complete
  end

  private

    def account
      @account ||= trading212_account.current_account
    end

    def update_account_balance!
      trading212_account.validate_currency!(trading212_account.currency)
      trading212_account.validate_currency!(trading212_account.snapshot.currency) if trading212_account.raw_summary_payload.present?
      trading212_account.snapshot.validate! unless trading212_account.combined?
      total_balance = trading212_account.account_balance || 0
      # Allocated, uninvested Pie cash stays inside the portfolio value. Main
      # and Spending Pot cash belong only to the Cash sibling.
      cash_balance = trading212_account.portfolio? ? trading212_account.snapshot.cash_in_pies : (trading212_account.cash? ? total_balance : trading212_account.cash_balance || 0)

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: trading212_account.currency
      )
      account.save!
      result = account.set_current_balance(total_balance, schedule_sync: false)
      raise Trading212Account::Snapshot::Invalid, result.error unless result.success?
    end
end
