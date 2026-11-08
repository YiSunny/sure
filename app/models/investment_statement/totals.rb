class InvestmentStatement::Totals
  def initialize(family, account_ids:, date_range:, income_account_ids: account_ids)
    @family = family
    @account_ids = account_ids
    @date_range = date_range
    @income_account_ids = income_account_ids
  end

  def call
    return empty_result if @account_ids.empty?

    result = ActiveRecord::Base.connection.select_one(query_sql)
    income = ActiveRecord::Base.connection.select_one(ActiveRecord::Base.sanitize_sql_array([ income_sql, sql_params.merge(income_account_ids: @income_account_ids) ]))

    {
      contributions: result["contributions"]&.to_d || 0,
      withdrawals: result["withdrawals"]&.to_d || 0,
      dividends: income["dividends"].to_d,
      interest: income["interest"].to_d,
      trades_count: result["trades_count"]&.to_i || 0
    }
  end

  private
    def income_sql
      <<~SQL
        SELECT
          COALESCE(SUM(CASE WHEN t.investment_activity_label = 'Dividend' THEN -entries.amount * COALESCE(er.rate, 1) ELSE 0 END), 0) AS dividends,
          COALESCE(SUM(CASE WHEN t.investment_activity_label = 'Interest' THEN -entries.amount * COALESCE(er.rate, 1) ELSE 0 END), 0) AS interest
        FROM entries
        JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'
        JOIN accounts ON accounts.id = entries.account_id
        LEFT JOIN exchange_rates er ON er.date = entries.date AND er.from_currency = entries.currency AND er.to_currency = :target_currency
        WHERE entries.account_id IN (:income_account_ids)
          AND accounts.family_id = :family_id
          AND accounts.status IN ('draft', 'active') AND accounts.exclude_from_reports = false
          AND entries.date BETWEEN :start_date AND :end_date AND entries.excluded = false
          AND t.kind NOT IN ('unclassified', 'funds_movement', 'cc_payment', 'one_time')
          #{Transaction.pending_providers_sql}
          #{Transaction.classified_for_reporting_sql("t")}
          AND (entries.account_id IN (:account_ids) OR (
            entries.source = 'trading212' AND (
              t.investment_activity_label = 'Dividend' OR
              (t.investment_activity_label = 'Interest' AND t.extra -> 'trading212' ->> 'type' = 'LENDING_INTEREST')
            )
          ))
      SQL
    end

    def empty_result
      {
        contributions: 0,
        withdrawals: 0,
        dividends: 0,
        interest: 0,
        trades_count: 0
      }
    end

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        aggregation_sql,
        sql_params
      ])
    end

    # Aggregate trades by direction (buy vs sell)
    # Buys (qty > 0) = contributions (cash going out to buy securities)
    # Sells (qty < 0) = withdrawals (cash coming in from selling securities)
    # Missing FX rates preserve InvestmentStatement's existing 1:1 fallback.
    #
    # account_ids is already scoped to the family's visible (draft/active)
    # investment accounts, so the query trusts that input and skips a join back
    # to accounts for family/status filtering.
    def aggregation_sql
      <<~SQL
        SELECT
          COALESCE(SUM(CASE WHEN trades.qty > 0 AND (trades.extra -> 'trading212' ->> 'funding_type') IS DISTINCT FROM 'referral_reward' THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as contributions,
          COALESCE(SUM(CASE WHEN trades.qty < 0 THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as withdrawals,
          COUNT(trades.id) as trades_count
        FROM entries
        JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'
        LEFT JOIN exchange_rates er ON (
          er.date = entries.date AND
          er.from_currency = entries.currency AND
          er.to_currency = :target_currency
        )
        WHERE entries.account_id IN (:account_ids)
          AND entries.date BETWEEN :start_date AND :end_date
          AND entries.excluded = false
      SQL
    end

    def sql_params
      {
        target_currency: @family.currency,
        family_id: @family.id,
        account_ids: @account_ids,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }
    end
end
