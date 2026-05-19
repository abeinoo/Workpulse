class AddAttendanceSourceColumns < ActiveRecord::Migration[8.0]
  def change
    # Per-employee attendance source permissions
    add_column :users, :allow_mobile_attendance,    :boolean, null: false, default: true
    add_column :users, :allow_biometric_attendance, :boolean, null: false, default: true

    # Track which source (mobile / biometric) generated each punch log
    add_column :biometric_punch_logs, :source, :string, null: false, default: "biometric"
    add_index  :biometric_punch_logs, :source
  end
end
