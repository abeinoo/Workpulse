class CreateStockIssueImportBatches < ActiveRecord::Migration[8.0]
  def change
    create_table :stock_issue_import_batches do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :warehouse,   null: false, foreign_key: true
      t.references :branch,      null: false, foreign_key: true
      t.references :created_by,  foreign_key: { to_table: :users }
      t.references :stock_issue,            foreign_key: true
      t.references :completion_stock_issue, foreign_key: { to_table: :stock_issues }
      t.string :status, null: false, default: "draft"
      t.timestamps
    end

    add_index :stock_issue_import_batches, :status

    create_table :stock_issue_import_rows do |t|
      t.references :batch, null: false, foreign_key: { to_table: :stock_issue_import_batches }
      t.references :product, foreign_key: true
      t.integer :row_number, null: false
      t.string  :sku
      t.decimal :quantity, precision: 12, scale: 3
      t.decimal :available_hint, precision: 12, scale: 3
      t.string  :status, null: false, default: "pending"
      t.string  :failure_reason
      t.timestamps
    end

    add_index :stock_issue_import_rows, [ :batch_id, :status ]
  end
end
