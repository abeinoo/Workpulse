class CreateFinanceBankStatements < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_statements do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :branch,                   foreign_key: true
      t.references :imported_by, null: false, foreign_key: { to_table: :users }

      t.string  :file_name,      null: false
      t.date    :statement_from, null: false
      t.date    :statement_to,   null: false
      t.string  :status,         null: false, default: "pending"
      t.jsonb   :column_mapping, null: false, default: {}
      t.integer :total_rows,     null: false, default: 0
      t.integer :matched_rows,   null: false, default: 0
      t.integer :unmatched_rows, null: false, default: 0
      t.integer :failed_rows,    null: false, default: 0
      t.text    :notes

      t.timestamps null: false
    end

    add_index :bank_statements, [:business_id, :status]
    add_index :bank_statements, [:business_id, :statement_from, :statement_to],
              name: "idx_bank_statements_on_business_date_range"
    add_index :bank_statements, [:business_id, :branch_id]
  end
end
