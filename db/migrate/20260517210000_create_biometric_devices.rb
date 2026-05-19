class CreateBiometricDevices < ActiveRecord::Migration[8.0]
  def change
    create_table :biometric_devices do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,          null: false
      t.string  :token,         null: false
      t.string  :location_note
      t.boolean :active,        null: false, default: true
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :biometric_devices, :token, unique: true
    add_index :biometric_devices, [:business_id, :name], unique: true
  end
end
