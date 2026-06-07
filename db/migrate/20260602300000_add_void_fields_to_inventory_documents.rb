class AddVoidFieldsToInventoryDocuments < ActiveRecord::Migration[8.1]
  def change
    %i[goods_receipts stock_issues stock_transfers].each do |table|
      add_column table, :voided_at,   :datetime
      add_reference table, :voided_by, foreign_key: { to_table: :users }
      add_column table, :void_reason, :text
    end
  end
end
