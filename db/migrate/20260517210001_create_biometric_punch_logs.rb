class CreateBiometricPunchLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :biometric_punch_logs do |t|
      t.references :business,         null: false, foreign_key: true
      t.references :biometric_device, null: true,  foreign_key: true
      t.references :employee,         null: true,  foreign_key: { to_table: :users }
      t.references :attendance_record, null: true,  foreign_key: true
      t.date     :work_date
      t.datetime :punched_at,   null: false
      t.datetime :received_at,  null: false
      t.string   :action,       null: false
      t.string   :ip_address
      t.text     :raw_payload
      t.text     :error_message

      t.timestamps
    end

    add_index :biometric_punch_logs, :action
    add_index :biometric_punch_logs, :punched_at
    add_index :biometric_punch_logs, :received_at
    add_index :biometric_punch_logs, [:employee_id, :punched_at]
  end
end
