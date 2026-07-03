class AddSoftDeleteToBankStatements < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_statements, :deleted_at,      :datetime
    add_column :bank_statements, :deleted_by_id,   :bigint
    add_column :bank_statements, :deletion_notes,  :text

    add_foreign_key :bank_statements, :users, column: :deleted_by_id
    add_index       :bank_statements, :deleted_at
  end
end
