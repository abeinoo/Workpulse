class CreatePurchaseRequests < ActiveRecord::Migration[8.1]
  # One Purchase Request per supplier (see Inventory::PurchaseRequestCreator).
  # idempotency_key is shared across every request created in a single
  # supplier-grouped submission, so uniqueness is scoped to (key, supplier)
  # rather than to the bare key — that's what stops the SAME supplier's
  # request from being double-created under a retried key, while still
  # allowing several suppliers to legitimately share that key in one batch.
  def change
    create_table :purchase_requests do |t|
      t.references :business, null: false, foreign_key: true
      t.references :supplier, null: false, foreign_key: true
      t.string :status, null: false, default: "draft"
      t.string :request_number, null: false
      t.string :source
      t.references :created_by, foreign_key: { to_table: :users }, null: true
      t.text :notes
      t.string :idempotency_key

      t.timestamps
    end

    add_index :purchase_requests, [ :business_id, :request_number ], unique: true
    add_index :purchase_requests, [ :idempotency_key, :supplier_id ], unique: true,
              where: "idempotency_key IS NOT NULL", name: "index_purchase_requests_on_idem_key_and_supplier"

    create_table :purchase_request_items do |t|
      t.references :purchase_request, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.decimal :unit_price, precision: 12, scale: 4, null: false
      t.decimal :total_cost, precision: 14, scale: 4, null: false, default: "0.0"
      t.references :source_warehouse, foreign_key: { to_table: :warehouses }, null: true
      t.text :notes

      t.timestamps
    end
  end
end
