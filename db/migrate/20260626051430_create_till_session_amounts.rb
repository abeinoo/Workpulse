class CreateTillSessionAmounts < ActiveRecord::Migration[8.1]
  def change
    create_table :till_session_amounts do |t|
      t.references :till_session,         null: false, foreign_key: true
      t.references :payment_method,       null: false, foreign_key: true
      t.string     :payment_method_name,  null: false
      t.decimal    :collected_amount,     precision: 12, scale: 2, null: false, default: "0.0"
      t.decimal    :refund_amount,        precision: 12, scale: 2, null: false, default: "0.0"
      t.timestamps
    end

    add_index :till_session_amounts,
              [:till_session_id, :payment_method_id],
              unique: true,
              name: "idx_till_session_amounts_unique_method"
  end
end
