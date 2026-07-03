class AddPreviewDataToImportRecords < ActiveRecord::Migration[8.0]
  def change
    add_column :pos_imports,    :preview_data, :jsonb, null: false, default: {}
    add_column :bank_statements, :preview_data, :jsonb, null: false, default: {}
  end
end
