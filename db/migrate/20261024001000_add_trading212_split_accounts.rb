class AddTrading212SplitAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :trading212_accounts, :kind, :string, null: false, default: "combined"
    add_column :trading212_accounts, :raw_summary_payload, :jsonb, null: false, default: {}
    add_column :trading212_accounts, :statement_enrichments, :jsonb, null: false, default: {}
    add_column :trading212_accounts, :split_audit_payload, :jsonb, null: false, default: {}
    remove_index :trading212_accounts, [ :trading212_item_id, :trading212_account_id ],
      name: "index_trading212_accounts_on_item_and_account_id", unique: true, where: "trading212_account_id IS NOT NULL"
    add_index :trading212_accounts, [ :trading212_item_id, :trading212_account_id, :kind ],
      unique: true, where: "trading212_account_id IS NOT NULL", name: "index_trading212_accounts_on_item_account_kind"
    add_check_constraint :trading212_accounts, "kind IN ('combined', 'cash', 'portfolio')", name: "trading212_accounts_kind"

    create_table :trading212_statements, id: :uuid do |t|
      t.references :trading212_account, null: false, type: :uuid, foreign_key: true
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.string :checksum, null: false
      t.string :status, null: false, default: "preview"
      t.jsonb :rows, null: false, default: []
      t.jsonb :result, null: false, default: {}
      t.date :coverage_start
      t.date :coverage_end
      t.timestamps
    end
    add_index :trading212_statements, [ :trading212_account_id, :checksum ], unique: true, name: "index_trading212_statements_on_account_checksum"
    reversible do |direction|
      direction.down do
        split = select_value("SELECT 1 FROM trading212_accounts WHERE kind <> 'combined' LIMIT 1")
        statements = select_value("SELECT 1 FROM trading212_statements LIMIT 1")
        raise ActiveRecord::IrreversibleMigration, "Restore or consolidate split accounts/statements before removing their schema" if split || statements
      end
    end
  end
end
