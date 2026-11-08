class HardenTrading212Accounting < ActiveRecord::Migration[8.1]
  def change
    # Keep native quotes/cost basis separate from a broker's dated wallet value.
    add_column :holdings, :provider_value, :decimal, precision: 19, scale: 4
    add_column :holdings, :provider_value_currency, :string
    add_column :trading212_accounts, :settlement_allocations, :jsonb, null: false, default: {}
    add_column :trading212_accounts, :last_processed_at, :datetime
    reversible do |direction|
      direction.down do
        reviewed = select_value("SELECT 1 FROM trading212_accounts WHERE settlement_allocations <> '{}'::jsonb LIMIT 1")
        values = select_value("SELECT 1 FROM holdings WHERE provider_value IS NOT NULL LIMIT 1")
        unclassified = select_value("SELECT 1 FROM transactions WHERE kind = 'unclassified' LIMIT 1")
        raise ActiveRecord::IrreversibleMigration, "Preserve funding reviews, unclassified activity and provider valuations before rolling back" if reviewed || values || unclassified
      end
    end
  end
end
