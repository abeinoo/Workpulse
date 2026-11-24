# Decision 17 (docs/inventory/multi_unit_nested_packaging_design.md §11.1): every
# change of a product's stored average cost is recorded, in the same
# transaction as the change, append-only. A row exists for automated runs too
# (system = true, actor optional), so the record never depends on a user being
# available; an AuditLog entry is written in addition whenever an actor is known.
class CreateInventoryAverageCostChanges < ActiveRecord::Migration[8.1]
  def up
    create_table :inventory_average_cost_changes do |t|
      t.references :business, null: false, foreign_key: true
      t.references :product,  null: false, foreign_key: true
      t.decimal :previous_average_cost, precision: 16, scale: 8, null: false
      t.decimal :new_average_cost,      precision: 16, scale: 8, null: false
      t.decimal :on_hand_before, precision: 14, scale: 3
      t.decimal :quantity,       precision: 14, scale: 3
      t.decimal :unit_cost,      precision: 16, scale: 8
      t.string  :trigger, null: false
      t.string  :source_type
      t.bigint  :source_id
      t.references :inventory_movement, foreign_key: true
      t.string :operation_ref
      t.references :actor, foreign_key: { to_table: :users }
      t.boolean :system, null: false, default: false
      t.jsonb   :metadata, null: false, default: {}
      t.datetime :created_at, null: false

      t.check_constraint "trigger IN ('receipt_posted', 'opening_balance_posted', 'document_voided', 'manual_recalculation', 'batch_replay')",
                         name: "inventory_average_cost_changes_trigger_check"
      t.check_constraint "actor_id IS NOT NULL OR system", name: "inventory_average_cost_changes_actor_or_system"
    end
    add_index :inventory_average_cost_changes, %i[source_type source_id], name: "index_inventory_average_cost_changes_on_source"
    add_index :inventory_average_cost_changes, :operation_ref

    execute <<~SQL
      CREATE FUNCTION inventory_average_cost_changes_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'inventory_average_cost_changes is append-only (% refused)', TG_OP
          USING ERRCODE = 'check_violation', CONSTRAINT = 'inventory_average_cost_changes_append_only';
      END
      $$;

      CREATE TRIGGER inventory_average_cost_changes_append_only BEFORE UPDATE OR DELETE ON inventory_average_cost_changes
        FOR EACH ROW EXECUTE FUNCTION inventory_average_cost_changes_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS inventory_average_cost_changes_append_only ON inventory_average_cost_changes;
      DROP FUNCTION IF EXISTS inventory_average_cost_changes_append_only();
    SQL
    drop_table :inventory_average_cost_changes
  end
end
