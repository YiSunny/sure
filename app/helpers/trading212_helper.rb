module Trading212Helper
  def trading212_diagnostics_message(diagnostics)
    t("trading212_split.diagnostics",
      processed: diagnostics[:processed_at] ? l(diagnostics[:processed_at], format: :long) : t("trading212_split.never"),
      fetched: diagnostics[:fetched_at] ? l(diagnostics[:fetched_at], format: :long) : t("trading212_split.never"),
      unresolved: diagnostics[:unresolved_settlements], unsupported: diagnostics[:unsupported_activities]) +
      (diagnostics[:reconciliation_difference] ? " #{t('trading212_split.quote_difference', amount: format_money(Money.new(diagnostics[:reconciliation_difference], diagnostics[:currency])))}" : "") +
      ((diagnostics[:stale] || diagnostics[:sync_failed]) ? " #{t('trading212_split.stale_data')}" : "")
  end

  def trading212_cash_flow(row)
    amount = row.fetch("amount").to_d
    direction = amount.negative? ? "inflow" : "outflow"
    t("trading212_split.#{direction}", amount: format_money(Money.new(amount.abs, row.fetch("currency"))))
  end

  def trading212_split_summary(summary)
    amounts = summary.slice(:total, :cash, :investments).transform_values { |value| format_money(Money.new(value, summary[:currency])) }
    t("trading212_split.summary", **amounts, **summary.slice(:cash_entries, :transfers_to_review))
  end
end
