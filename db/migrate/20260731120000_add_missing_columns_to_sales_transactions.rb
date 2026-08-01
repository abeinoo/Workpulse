class AddMissingColumnsToSalesTransactions < ActiveRecord::Migration[8.1]
  # Root cause (see audit): sales_transactions (originally created as
  # pos_transactions by 20260703240001, renamed by 20260730140000) is
  # missing several columns that db/schema.rb has always shown as part of
  # this table: branch_id, fees, product_name, status, superseded_at,
  # terminal_id, transaction_time — plus the composite unique index
  # idx_pos_txn_business_transaction_id_unique.
  #
  # None of these were ever added by a migration file that still exists in
  # db/migrate/. They were added by ~20 migrations (dated 2026-07-28 through
  # 2026-07-30) from an earlier, abandoned attempt at the POS-import feature
  # that were later deleted from the repo without ever being rolled back —
  # the exact same pattern already diagnosed and fixed for
  # expenses.source_pos_import_id in 20260730150300. Local/dev databases
  # that ran those deleted migrations before they were removed still carry
  # every one of these columns (confirmed via 21 orphaned rows in the local
  # schema_migrations table with no matching file); any database built
  # purely by replaying the CURRENT db/migrate/*.rb in order — production,
  # or a fresh `db:migrate` setup — never got them, which is what makes
  # Finance::SalesImports::Importer's insert_all (which writes
  # transaction_time:) raise ActiveModel::UnknownAttributeError there.
  #
  # transaction_time specifically IS actively read/written by real business
  # logic (Finance::SalesImports::CsvParser/Importer, the DR show page's
  # Sales Transactions tables, Finance::PosVerification::Comparator's
  # Amount+Date+Time-Window matching tier) — never a mistaken/unused field.
  # branch_id/fees/product_name/superseded_at/terminal_id/status are
  # currently unused by any app code but are restored anyway for full
  # schema.rb parity, so the same class of crash can't resurface the moment
  # a future change starts reading one of them.
  #
  # Every add_column/add_index/add_foreign_key is guarded so this is safe to
  # run regardless of which of these already exist on a given database —
  # never assumes any of them are present or absent.
  def up
    unless column_exists?(:sales_transactions, :branch_id)
      add_column :sales_transactions, :branch_id, :bigint
    end
    unless column_exists?(:sales_transactions, :fees)
      add_column :sales_transactions, :fees, :decimal, precision: 15, scale: 4
    end
    unless column_exists?(:sales_transactions, :product_name)
      add_column :sales_transactions, :product_name, :string
    end
    unless column_exists?(:sales_transactions, :status)
      add_column :sales_transactions, :status, :string, default: "successful", null: false
    end
    unless column_exists?(:sales_transactions, :superseded_at)
      add_column :sales_transactions, :superseded_at, :datetime
    end
    unless column_exists?(:sales_transactions, :terminal_id)
      add_column :sales_transactions, :terminal_id, :string
    end
    unless column_exists?(:sales_transactions, :transaction_time)
      add_column :sales_transactions, :transaction_time, :time
    end

    unless foreign_key_exists?(:sales_transactions, :branches)
      add_foreign_key :sales_transactions, :branches
    end

    unless index_exists?(:sales_transactions, :branch_id)
      add_index :sales_transactions, :branch_id
    end
    unless index_exists?(:sales_transactions, :status)
      add_index :sales_transactions, :status
    end
    unless index_exists?(:sales_transactions, :superseded_at)
      add_index :sales_transactions, :superseded_at
    end
    unless index_exists?(:sales_transactions, :terminal_id)
      add_index :sales_transactions, :terminal_id
    end
    unless index_exists?(:sales_transactions, [ :business_id, :transaction_id ],
                          name: "idx_pos_txn_business_transaction_id_unique")
      add_index :sales_transactions, [ :business_id, :transaction_id ], unique: true,
                where: "transaction_id IS NOT NULL AND superseded_at IS NULL",
                name: "idx_pos_txn_business_transaction_id_unique"
    end
  end

  def down
    if index_exists?(:sales_transactions, nil, name: "idx_pos_txn_business_transaction_id_unique")
      remove_index :sales_transactions, name: "idx_pos_txn_business_transaction_id_unique"
    end
    if index_exists?(:sales_transactions, :terminal_id)
      remove_index :sales_transactions, :terminal_id
    end
    if index_exists?(:sales_transactions, :superseded_at)
      remove_index :sales_transactions, :superseded_at
    end
    if index_exists?(:sales_transactions, :status)
      remove_index :sales_transactions, :status
    end
    if index_exists?(:sales_transactions, :branch_id)
      remove_index :sales_transactions, :branch_id
    end

    if foreign_key_exists?(:sales_transactions, :branches)
      remove_foreign_key :sales_transactions, :branches
    end

    if column_exists?(:sales_transactions, :transaction_time)
      remove_column :sales_transactions, :transaction_time, :time
    end
    if column_exists?(:sales_transactions, :terminal_id)
      remove_column :sales_transactions, :terminal_id, :string
    end
    if column_exists?(:sales_transactions, :superseded_at)
      remove_column :sales_transactions, :superseded_at, :datetime
    end
    if column_exists?(:sales_transactions, :status)
      remove_column :sales_transactions, :status, :string
    end
    if column_exists?(:sales_transactions, :product_name)
      remove_column :sales_transactions, :product_name, :string
    end
    if column_exists?(:sales_transactions, :fees)
      remove_column :sales_transactions, :fees, :decimal
    end
    if column_exists?(:sales_transactions, :branch_id)
      remove_column :sales_transactions, :branch_id, :bigint
    end
  end
end
