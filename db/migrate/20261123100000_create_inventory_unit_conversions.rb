# The Unit Conversion document (docs/inventory/multi_unit_nested_packaging_design.md §14, P6):
# changes a product's base unit (its Measure) with an owner-entered factor,
# without rewriting history.
#
# * inventory_unit_conversions / _lines — the document: from / to unit,
#   factor (1 old unit = factor new units), reason, per-warehouse quantities,
#   values, average before / after, packaging and threshold snapshots, and
#   the movement high-water marks that bound the conversion in the ledger.
# * inventory_movements.unit_of_measure — the unit a NEW movement is recorded
#   in (NULL on history: the unit in force when it was posted, read from the
#   conversion history). Existing rows are not touched.
# * products.unit_converted_at — when the product's unit last changed.
# * unit_of_measure on every document line table — the unit the line was
#   entered in (NULL on existing rows). A line entered in another unit than the
#   product's current one is never posted, and history displays its own unit.
# * inventory_average_cost_changes accepts the trigger 'unit_conversion'.
class CreateInventoryUnitConversions < ActiveRecord::Migration[8.1]
  LINE_TABLES = %i[purchase_request_items goods_receipt_items stock_issue_items stock_transfer_items stock_adjustment_items].freeze
  TRIGGERS_BEFORE = %w[receipt_posted opening_balance_posted document_voided manual_recalculation batch_replay].freeze

  def up
    create_table :inventory_unit_conversions do |t|
      t.references :business, null: false, foreign_key: true
      t.references :product,  null: false, foreign_key: true
      t.string  :conversion_number, null: false
      t.string  :from_unit, null: false
      t.string  :to_unit,   null: false
      t.decimal :factor, precision: 20, scale: 10, null: false
      t.text    :reason, null: false
      t.string  :status, null: false, default: "posted"
      t.decimal :stock_before, precision: 14, scale: 3, null: false, default: 0
      t.decimal :stock_after,  precision: 14, scale: 3, null: false, default: 0
      t.decimal :value_before, precision: 16, scale: 4, null: false, default: 0
      t.decimal :value_after,  precision: 16, scale: 4, null: false, default: 0
      t.decimal :previous_average_cost, precision: 16, scale: 8, null: false
      t.decimal :new_average_cost,      precision: 16, scale: 8, null: false
      t.decimal :previous_last_purchase_price, precision: 16, scale: 8
      t.decimal :new_last_purchase_price,      precision: 16, scale: 8
      t.decimal :previous_measure_amount, precision: 12, scale: 3
      t.decimal :new_measure_amount,      precision: 12, scale: 3
      t.datetime :previous_unit_converted_at
      t.bigint  :movements_before_id                 # highest movement id of the product before posting
      t.bigint  :movements_after_id                  # highest movement id after posting (void boundary)
      t.jsonb   :packaging_snapshot, null: false, default: {}
      t.jsonb   :thresholds_snapshot, null: false, default: {}
      t.references :posted_by, null: false, foreign_key: { to_table: :users }
      t.datetime :posted_at, null: false
      t.references :voided_by, foreign_key: { to_table: :users }
      t.datetime :voided_at
      t.text :void_reason
      t.timestamps

      t.check_constraint "factor > 0", name: "inventory_unit_conversions_factor_positive"
      t.check_constraint "from_unit <> to_unit", name: "inventory_unit_conversions_units_differ"
      t.check_constraint "status IN ('posted', 'voided')", name: "inventory_unit_conversions_status_check"
      t.check_constraint "(status = 'voided') = (voided_at IS NOT NULL)", name: "inventory_unit_conversions_voided_at"
      t.check_constraint "length(btrim(reason)) > 0", name: "inventory_unit_conversions_reason_present"
    end
    add_index :inventory_unit_conversions, %i[business_id conversion_number], unique: true

    create_table :inventory_unit_conversion_lines do |t|
      t.references :inventory_unit_conversion, null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.decimal :quantity_before, precision: 14, scale: 3, null: false
      t.decimal :quantity_after,  precision: 14, scale: 3, null: false
      t.jsonb   :packages, null: false, default: {}  # { package unit => sealed packages carried over }
      t.references :out_movement, foreign_key: { to_table: :inventory_movements }
      t.references :in_movement,  foreign_key: { to_table: :inventory_movements }
      t.timestamps
    end
    add_index :inventory_unit_conversion_lines, %i[inventory_unit_conversion_id warehouse_id], unique: true,
              name: "index_unit_conversion_lines_on_conversion_and_warehouse"

    add_column :inventory_movements, :unit_of_measure, :string
    add_column :products, :unit_converted_at, :datetime
    LINE_TABLES.each { |table| add_column table, :unit_of_measure, :string }

    remove_check_constraint :inventory_average_cost_changes, name: "inventory_average_cost_changes_trigger_check"
    add_check_constraint :inventory_average_cost_changes,
                         "trigger IN (#{(TRIGGERS_BEFORE + [ 'unit_conversion' ]).map { |t| "'#{t}'" }.join(', ')})",
                         name: "inventory_average_cost_changes_trigger_check"
  end

  def down
    remove_check_constraint :inventory_average_cost_changes, name: "inventory_average_cost_changes_trigger_check"
    add_check_constraint :inventory_average_cost_changes,
                         "trigger IN (#{TRIGGERS_BEFORE.map { |t| "'#{t}'" }.join(', ')})",
                         name: "inventory_average_cost_changes_trigger_check"
    LINE_TABLES.each { |table| remove_column table, :unit_of_measure, if_exists: true }
    remove_column :products, :unit_converted_at
    remove_column :inventory_movements, :unit_of_measure
    drop_table :inventory_unit_conversion_lines
    drop_table :inventory_unit_conversions
  end
end
