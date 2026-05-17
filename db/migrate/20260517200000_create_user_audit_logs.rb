class CreateUserAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :user_audit_logs do |t|
      t.references :actor,       null: false, foreign_key: { to_table: :users }
      t.references :target_user, null: false, foreign_key: { to_table: :users }
      t.string     :action,      null: false
      t.string     :ip_address
      t.timestamps
    end

    add_index :user_audit_logs, :action
    add_index :user_audit_logs, :created_at
  end
end
