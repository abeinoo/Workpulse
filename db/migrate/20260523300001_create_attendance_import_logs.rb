class CreateAttendanceImportLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :attendance_import_logs do |t|
      t.references :business,     null: false, foreign_key: true
      t.references :imported_by,  null: false, foreign_key: { to_table: :users }
      t.string  :filename,          null: false
      t.string  :status,            null: false, default: "pending"
      t.integer :total_rows,        null: false, default: 0
      t.integer :imported_rows,     null: false, default: 0
      t.integer :failed_rows_count, null: false, default: 0
      t.jsonb   :metadata,          null: false, default: {}
      t.timestamps
    end

    add_index :attendance_import_logs, [ :business_id, :created_at ]
  end
end
