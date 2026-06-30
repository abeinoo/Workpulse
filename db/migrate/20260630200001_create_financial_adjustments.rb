class CreateFinancialAdjustments < ActiveRecord::Migration[8.0]
  def change
    create_table :financial_adjustments do |t|
      # Polymorphic target — the financial object this adjustment annotates.
      t.string  :adjustable_type, null: false
      t.bigint  :adjustable_id,   null: false

      t.bigint  :business_id,     null: false
      t.bigint  :actor_id,        null: false

      # Optional: approving manager for adjustments that require sign-off.
      t.bigint   :approved_by_id
      t.datetime :approved_at

      # Reason taxonomy + mandatory free-text explanation.
      t.string :reason_code, null: false
      t.text   :notes,       null: false

      # Full before/after snapshots.  Content is opaque to this table —
      # the service layer owns the schema for each adjustable_type.
      t.jsonb :before_data, null: false, default: {}
      t.jsonb :after_data,  null: false, default: {}

      t.timestamps null: false
    end

    add_index :financial_adjustments, %i[adjustable_type adjustable_id],
              name: "index_financial_adjustments_on_adjustable"
    add_index :financial_adjustments, :business_id,   name: "index_financial_adjustments_on_business_id"
    add_index :financial_adjustments, :actor_id,      name: "index_financial_adjustments_on_actor_id"
    add_index :financial_adjustments, :approved_by_id, name: "index_financial_adjustments_on_approved_by_id"
    add_index :financial_adjustments, :reason_code,   name: "index_financial_adjustments_on_reason_code"
    add_index :financial_adjustments, :created_at,    name: "index_financial_adjustments_on_created_at"

    add_foreign_key :financial_adjustments, :businesses
    add_foreign_key :financial_adjustments, :users, column: :actor_id
    add_foreign_key :financial_adjustments, :users, column: :approved_by_id
  end
end
