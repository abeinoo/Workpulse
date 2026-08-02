class CreateEmployeeInsuranceProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_insurance_profiles do |t|
      t.references :business, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.references :created_by, null: false, foreign_key: { to_table: :users }

      t.boolean :insured, null: false, default: false
      t.decimal :employee_contribution_amount, precision: 12, scale: 2, null: false, default: 0
      t.decimal :employer_contribution_amount, precision: 12, scale: 2, null: false, default: 0
      t.date :insurance_start_date
      t.date :insurance_end_date
      t.string :insurance_number
      t.text :notes

      t.timestamps
    end
  end
end
