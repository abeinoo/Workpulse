# Product measurement is informational only: Unit of Measure and Amount
# describe the product and never constrain or drive inventory. The packaging
# feature has been removed from the application, but three database objects
# of db/migrate/20261123091000 still enforced its rule that
# products.measure_amount equals the innermost active packaging level's
# content (error "measure_amount of product … must equal its innermost
# packaging content"):
#
#   * trigger  products_check_packaging_structure ON products (and its function)
#   * trigger  product_packaging_levels_check_structure ON product_packaging_levels
#              (and its function)
#   * function inventory_check_packaging_structure(bigint), called by both
#
# This migration drops exactly those. Nothing else changes: no table, column,
# row or index is touched; the packaging tables keep their history and their
# protection triggers (product_packaging_levels_immutable,
# inventory_packaging_entries_append_only). Every statement is IF EXISTS /
# guarded, so it is a no-op on a database where the packaging schema was never
# created. `down` restores the three objects exactly as 20261123091000 created
# them (only where the packaging table exists).
class DropPackagingStructureChecks < ActiveRecord::Migration[8.1]
  def up
    execute "DROP TRIGGER IF EXISTS products_check_packaging_structure ON products"
    execute "DROP FUNCTION IF EXISTS products_check_packaging_structure()"
    if table_exists?(:product_packaging_levels)
      execute "DROP TRIGGER IF EXISTS product_packaging_levels_check_structure ON product_packaging_levels"
    end
    execute "DROP FUNCTION IF EXISTS product_packaging_levels_check_structure()"
    execute "DROP FUNCTION IF EXISTS inventory_check_packaging_structure(bigint)"
  end

  def down
    return unless table_exists?(:product_packaging_levels)

    execute <<~SQL
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
    SQL
  end
end
