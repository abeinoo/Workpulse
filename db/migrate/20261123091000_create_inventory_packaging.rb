# Nested packaging (docs/inventory/multi_unit_nested_packaging_design.md §4, §5):
#
# * product_packaging_levels — one linear chain per product, position 1
#   (innermost) .. 4 (outermost). A level's definition never changes once
#   written (trigger); it is retired, never edited. contains_quantity is the
#   base content (level 1) or the number of packages of the level below
#   (levels >= 2, whole). base_quantity = the chain product, in base units.
# * products.measure_amount must equal the active level 1's contains_quantity
#   whenever the product has packaging (Decisions 1 and 14): deferred constraint
#   triggers check the final state of each transaction.
# * inventory_packaging_entries — append-only packaging ledger (moved /
#   breakdown / count_correction / conversion). Free packages per level are the
#   SUM of package_delta; inventory_movements stays the stock and cost ledger.
class CreateInventoryPackaging < ActiveRecord::Migration[8.1]
  def up
    create_table :product_packaging_levels do |t|
      t.references :business, null: false, foreign_key: true
      t.references :product,  null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string  :package_unit, null: false
      t.decimal :contains_quantity, precision: 12, scale: 3, null: false
      t.decimal :base_quantity,     precision: 16, scale: 3, null: false
      t.string  :status, null: false, default: "active"
      t.datetime :retired_at
      t.references :retired_by, foreign_key: { to_table: :users }
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps

      t.check_constraint "position BETWEEN 1 AND 4", name: "product_packaging_levels_position_range"
      t.check_constraint "contains_quantity > 0", name: "product_packaging_levels_contains_positive"
      t.check_constraint "base_quantity > 0", name: "product_packaging_levels_base_positive"
      t.check_constraint "position = 1 OR contains_quantity = trunc(contains_quantity)", name: "product_packaging_levels_outer_whole"
      t.check_constraint "status IN ('active', 'retired')", name: "product_packaging_levels_status_check"
      t.check_constraint "(status = 'retired') = (retired_at IS NOT NULL)", name: "product_packaging_levels_retired_at"
    end
    add_index :product_packaging_levels, %i[product_id position], unique: true, where: "status = 'active'",
              name: "index_product_packaging_levels_active_position"
    add_index :product_packaging_levels, %i[product_id package_unit], unique: true, where: "status = 'active'",
              name: "index_product_packaging_levels_active_unit"
    add_index :product_packaging_levels, %i[id product_id], unique: true, name: "index_product_packaging_levels_on_id_and_product"

    create_table :inventory_packaging_entries do |t|
      t.references :business,  null: false, foreign_key: true
      t.references :product,   null: false, foreign_key: true, index: false
      t.references :warehouse, null: false, foreign_key: true, index: false
      t.bigint  :packaging_level_id, null: false
      t.integer :package_delta, null: false
      t.string  :kind, null: false
      t.references :inventory_movement, foreign_key: true
      t.string  :source_type
      t.bigint  :source_id
      t.date    :occurred_on, null: false
      t.datetime :created_at, null: false

      t.check_constraint "package_delta <> 0", name: "inventory_packaging_entries_delta_nonzero"
      t.check_constraint "kind IN ('moved', 'breakdown', 'count_correction', 'conversion')",
                         name: "inventory_packaging_entries_kind_check"
    end
    add_index :inventory_packaging_entries, %i[product_id warehouse_id packaging_level_id],
              name: "index_inventory_packaging_entries_balance"
    add_index :inventory_packaging_entries, %i[source_type source_id], name: "index_inventory_packaging_entries_on_source"
    add_foreign_key :inventory_packaging_entries, :product_packaging_levels,
                    column: %i[packaging_level_id product_id], primary_key: %i[id product_id],
                    name: "fk_inventory_packaging_entries_level_same_product"

    # Document lines: the unit the user entered (a packaging level, or NULL =
    # the base unit) and the amount in that unit. `quantity` stays the
    # canonical base quantity every stock calculation reads.
    %i[purchase_request_items goods_receipt_items stock_issue_items stock_transfer_items].each do |table|
      add_column table, :entered_quantity, :decimal, precision: 12, scale: 3
      add_column table, :packaging_level_id, :bigint
      add_index table, :packaging_level_id
      add_foreign_key table, :product_packaging_levels, column: %i[packaging_level_id product_id],
                      primary_key: %i[id product_id], name: "fk_#{table}_packaging_level_same_product"
      add_check_constraint table, "entered_quantity IS NULL OR entered_quantity > 0", name: "#{table}_entered_quantity_positive"
    end
    add_column :purchase_request_items, :entered_unit_price, :decimal, precision: 16, scale: 8
    add_column :goods_receipt_items, :entered_unit_cost, :decimal, precision: 16, scale: 8

    # Stocktake per-level counts ({ "level id" => packages, "loose" => base }) and
    # the per-level difference a stock-count adjustment line carries (§8).
    add_column :stock_count_items, :counted_breakdown, :jsonb
    add_column :stock_count_items, :system_breakdown, :jsonb
    add_column :stock_adjustment_items, :packaging_differences, :jsonb

    execute <<~SQL
      CREATE FUNCTION product_packaging_levels_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.product_id <> OLD.product_id OR NEW.business_id <> OLD.business_id OR NEW.position <> OLD.position
           OR NEW.package_unit <> OLD.package_unit OR NEW.contains_quantity <> OLD.contains_quantity
           OR NEW.base_quantity <> OLD.base_quantity THEN
          RAISE EXCEPTION 'a packaging level is never edited; retire it and add a new one'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'product_packaging_levels_immutable';
        END IF;
        IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
          RAISE EXCEPTION 'a retired packaging level stays retired'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'product_packaging_levels_immutable';
        END IF;
        RETURN NEW;
      END
      $$;

      CREATE TRIGGER product_packaging_levels_immutable BEFORE UPDATE ON product_packaging_levels
        FOR EACH ROW EXECUTE FUNCTION product_packaging_levels_immutable();

      CREATE FUNCTION inventory_check_packaging_structure(p_product_id bigint) RETURNS void LANGUAGE plpgsql AS $$
      DECLARE
        level_count integer;
        max_position integer;
        inner_content numeric;
        amount numeric;
      BEGIN
        SELECT count(*), max(position) INTO level_count, max_position
          FROM product_packaging_levels WHERE product_id = p_product_id AND status = 'active';
        IF level_count = 0 THEN
          RETURN;
        END IF;
        IF max_position <> level_count THEN
          RAISE EXCEPTION 'packaging levels of product % must be contiguous from 1', p_product_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'product_packaging_levels_contiguous';
        END IF;
        SELECT contains_quantity INTO inner_content
          FROM product_packaging_levels WHERE product_id = p_product_id AND status = 'active' AND position = 1;
        SELECT measure_amount INTO amount FROM products WHERE id = p_product_id;
        IF amount IS NULL OR amount <> inner_content THEN
          RAISE EXCEPTION 'measure_amount of product % must equal its innermost packaging content', p_product_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'products_measure_amount_matches_innermost_level';
        END IF;
      END
      $$;

      CREATE FUNCTION product_packaging_levels_check_structure() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM inventory_check_packaging_structure(NEW.product_id);
        RETURN NULL;
      END
      $$;

      CREATE CONSTRAINT TRIGGER product_packaging_levels_check_structure
        AFTER INSERT OR UPDATE ON product_packaging_levels DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION product_packaging_levels_check_structure();

      CREATE FUNCTION products_check_packaging_structure() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.measure_amount IS DISTINCT FROM OLD.measure_amount THEN
          PERFORM inventory_check_packaging_structure(NEW.id);
        END IF;
        RETURN NULL;
      END
      $$;

      CREATE CONSTRAINT TRIGGER products_check_packaging_structure
        AFTER UPDATE OF measure_amount ON products DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION products_check_packaging_structure();

      CREATE FUNCTION inventory_packaging_entries_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'inventory_packaging_entries is append-only (% refused)', TG_OP
          USING ERRCODE = 'check_violation', CONSTRAINT = 'inventory_packaging_entries_append_only';
      END
      $$;

      CREATE TRIGGER inventory_packaging_entries_append_only BEFORE UPDATE OR DELETE ON inventory_packaging_entries
        FOR EACH ROW EXECUTE FUNCTION inventory_packaging_entries_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS inventory_packaging_entries_append_only ON inventory_packaging_entries;
      DROP TRIGGER IF EXISTS products_check_packaging_structure ON products;
      DROP TRIGGER IF EXISTS product_packaging_levels_check_structure ON product_packaging_levels;
      DROP TRIGGER IF EXISTS product_packaging_levels_immutable ON product_packaging_levels;
      DROP FUNCTION IF EXISTS inventory_packaging_entries_append_only();
      DROP FUNCTION IF EXISTS products_check_packaging_structure();
      DROP FUNCTION IF EXISTS product_packaging_levels_check_structure();
      DROP FUNCTION IF EXISTS inventory_check_packaging_structure(bigint);
      DROP FUNCTION IF EXISTS product_packaging_levels_immutable();
    SQL
    remove_column :stock_adjustment_items, :packaging_differences
    remove_column :stock_count_items, :system_breakdown
    remove_column :stock_count_items, :counted_breakdown
    remove_column :goods_receipt_items, :entered_unit_cost
    remove_column :purchase_request_items, :entered_unit_price
    %i[purchase_request_items goods_receipt_items stock_issue_items stock_transfer_items].each do |table|
      remove_foreign_key table, name: "fk_#{table}_packaging_level_same_product"
      remove_check_constraint table, name: "#{table}_entered_quantity_positive"
      remove_column table, :packaging_level_id
      remove_column table, :entered_quantity
    end
    drop_table :inventory_packaging_entries
    drop_table :product_packaging_levels
  end
end
