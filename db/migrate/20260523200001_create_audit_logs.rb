class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.references :actor,    null: false, foreign_key: { to_table: :users }
      t.references :business, null: false, foreign_key: true
      t.string  :auditable_type, null: false
      t.bigint  :auditable_id,   null: false
      t.string  :action,         null: false
      t.jsonb   :changes_json,   null: false, default: {}
      t.jsonb   :metadata,       null: false, default: {}
      t.datetime :created_at,    null: false
    end

    add_index :audit_logs, %i[auditable_type auditable_id], name: "index_audit_logs_on_auditable"
    add_index :audit_logs, :created_at
  end
end
