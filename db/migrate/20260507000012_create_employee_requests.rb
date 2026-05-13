class CreateEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_requests do |t|
      t.references :user,        null: false, foreign_key: true
      t.references :branch,      null: false, foreign_key: true
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.string  :request_type,       null: false
      t.string  :status,             null: false, default: "pending"
      t.date    :requested_for_date, null: false
      t.decimal :amount,             precision: 12, scale: 2
      t.text    :reason,             null: false
      t.text    :response_note
      t.datetime :reviewed_at
      t.boolean :affects_payroll,    null: false, default: false
      t.timestamps
    end

    add_index :employee_requests, [ :user_id, :request_type, :requested_for_date ]
    add_index :employee_requests, [ :branch_id, :status ]
  end
end
