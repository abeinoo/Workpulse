# Stock Transfer redesign — Phase A (schema foundation). Approved 2026-11-25
# (decisions D1–D12). Adds, without changing any existing row's meaning:
#
#   * warehouses: the system "transit" kind — at most one per business, always
#     active, never a branch warehouse;
#   * database guards: no document / assignment / setting may reference the
#     transit warehouse, and the transit warehouse accepts only the transit
#     ledger legs (and those legs only there);
#   * stock_transfers: posting_mode — every existing transfer is "direct" (the
#     immediate source -> destination posting it already has; never
#     reinterpreted) — plus the dispatch / receipt lifecycle columns and
#     statuses for "via_transit" transfers (used from Phase B);
#   * stock_transfer_items.requested_quantity (NULL for history; set at
#     submission from Phase B);
#   * the append-only receipt and discrepancy-resolution ledgers (used from
#     Phases C / D).
#
# No existing row is updated except the default fill of the new
# posting_mode column ('direct'), which states what those rows already are.
# No movement, balance, item quantity or audit row is touched.
class AddTransitTransferFoundation < ActiveRecord::Migration[8.1]
  # Tables whose warehouse references must never point at the transit warehouse.
  OPERATIONAL_REFERENCES = {
    "goods_receipts"                  => %w[warehouse_id],
    "purchase_requests"               => %w[warehouse_id],
    "purchase_request_items"          => %w[source_warehouse_id],
    "stock_adjustments"               => %w[warehouse_id],
    "stock_counts"                    => %w[warehouse_id],
    "stock_issues"                    => %w[warehouse_id],
    "stock_issue_import_batches"      => %w[warehouse_id],
    "stock_transfers"                 => %w[source_warehouse_id destination_warehouse_id],
    "warehouse_assignments"           => %w[warehouse_id],
    "warehouse_branch_supplies"       => %w[warehouse_id],
    "product_warehouse_settings"      => %w[warehouse_id],
    "inventory_packaging_entries"     => %w[warehouse_id],
    "inventory_unit_conversion_lines" => %w[warehouse_id]
  }.freeze

  TRANSIT_REASONS = %w[transit_in transit_out transfer_loss].freeze
  DIRECT_STATUSES  = %w[draft pending_approval approved rejected cancelled].freeze
  TRANSIT_STATUSES = %w[draft pending_approval awaiting_dispatch in_transit discrepancy received rejected cancelled].freeze
  ALL_STATUSES     = (DIRECT_STATUSES + TRANSIT_STATUSES).uniq.freeze
  OLD_STATUSES     = DIRECT_STATUSES

  def up
    # ── warehouses: the system transit kind ────────────────────────────────
    remove_check_constraint :warehouses, name: "warehouses_kind_known"
    add_check_constraint :warehouses, "kind IS NULL OR kind IN ('central', 'branch', 'transit')", name: "warehouses_kind_known"
    add_check_constraint :warehouses, "kind IS DISTINCT FROM 'transit' OR status = 'active'", name: "warehouses_transit_always_active"
    add_index :warehouses, :business_id, unique: true, where: "kind = 'transit'", name: "index_warehouses_one_transit_per_business"

    execute <<~SQL
      CREATE FUNCTION public.reject_transit_warehouse_reference() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        column_name text;
        referenced  bigint;
      BEGIN
        FOREACH column_name IN ARRAY TG_ARGV LOOP
          referenced := (to_jsonb(NEW) ->> column_name)::bigint;
          IF referenced IS NOT NULL AND EXISTS (SELECT 1 FROM warehouses WHERE id = referenced AND kind = 'transit') THEN
            RAISE EXCEPTION '%.% cannot reference the system transit warehouse', TG_TABLE_NAME, column_name
              USING ERRCODE = 'check_violation';
          END IF;
        END LOOP;
        RETURN NEW;
      END;
      $$;
    SQL
    OPERATIONAL_REFERENCES.each do |table, columns|
      execute <<~SQL
        CREATE TRIGGER #{table}_operational_warehouse_only
        BEFORE INSERT OR UPDATE OF #{columns.join(', ')} ON #{table}
        FOR EACH ROW EXECUTE FUNCTION public.reject_transit_warehouse_reference(#{columns.map { |c| "'#{c}'" }.join(', ')});
      SQL
    end

    execute <<~SQL
      CREATE FUNCTION public.inventory_movements_transit_legs() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        transit boolean;
      BEGIN
        SELECT kind = 'transit' INTO transit FROM warehouses WHERE id = NEW.warehouse_id;
        IF coalesce(transit, false) <> (NEW.reason IN (#{TRANSIT_REASONS.map { |r| "'#{r}'" }.join(', ')})) THEN
          RAISE EXCEPTION 'inventory movement % in warehouse %: the transit warehouse takes only transit legs, and transit legs only go there',
            NEW.reason, NEW.warehouse_id USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    execute <<~SQL
      CREATE TRIGGER inventory_movements_transit_legs
      BEFORE INSERT OR UPDATE OF warehouse_id, reason ON inventory_movements
      FOR EACH ROW EXECUTE FUNCTION public.inventory_movements_transit_legs();
    SQL

    # ── stock_transfers: posting mode + dispatch / receipt lifecycle ─────────
    add_column :stock_transfers, :posting_mode, :string, null: false, default: "direct"
    add_column :stock_transfers, :dispatched_at, :datetime
    add_reference :stock_transfers, :dispatched_by, foreign_key: { to_table: :users }, index: true
    add_column :stock_transfers, :dispatched_on, :date
    add_column :stock_transfers, :received_at, :datetime
    add_index :stock_transfers, %i[business_id posting_mode status], name: "index_stock_transfers_on_business_mode_status"

    remove_check_constraint :stock_transfers, name: "stock_transfers_status_valid"
    add_check_constraint :stock_transfers, "status IN (#{quoted(ALL_STATUSES)})", name: "stock_transfers_status_valid"
    add_check_constraint :stock_transfers, "posting_mode IN ('direct', 'via_transit')", name: "stock_transfers_posting_mode_valid"
    add_check_constraint :stock_transfers,
                         "(posting_mode = 'direct' AND status IN (#{quoted(DIRECT_STATUSES)})) OR " \
                         "(posting_mode = 'via_transit' AND status IN (#{quoted(TRANSIT_STATUSES)}))",
                         name: "stock_transfers_status_matches_posting_mode"
    add_check_constraint :stock_transfers,
                         "status NOT IN ('in_transit', 'discrepancy', 'received') OR " \
                         "(dispatched_at IS NOT NULL AND dispatched_by_id IS NOT NULL AND dispatched_on IS NOT NULL)",
                         name: "stock_transfers_dispatch_recorded"
    add_check_constraint :stock_transfers, "status <> 'received' OR received_at IS NOT NULL",
                         name: "stock_transfers_receipt_recorded"

    add_column :stock_transfer_items, :requested_quantity, :decimal, precision: 12, scale: 3
    add_check_constraint :stock_transfer_items, "requested_quantity IS NULL OR requested_quantity > 0",
                         name: "stock_transfer_items_requested_quantity_positive"

    # ── append-only receipt / resolution ledgers ─────────────────────────────
    create_table :stock_transfer_receipts do |t|
      t.references :business,       null: false, foreign_key: true
      t.references :stock_transfer, null: false, foreign_key: true
      t.references :received_by,    null: false, foreign_key: { to_table: :users }
      t.datetime :received_at, null: false
      t.date     :received_on, null: false
      t.boolean  :closes_with_shortfall, null: false, default: false
      t.text     :notes
      t.datetime :created_at, null: false
    end

    create_table :stock_transfer_receipt_lines do |t|
      t.references :stock_transfer_receipt, null: false, foreign_key: true
      t.references :stock_transfer_item,    null: false, foreign_key: true
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.datetime :created_at, null: false
      t.index %i[stock_transfer_receipt_id stock_transfer_item_id], unique: true, name: "index_receipt_lines_one_per_item"
      t.check_constraint "quantity > 0", name: "stock_transfer_receipt_lines_quantity_positive"
    end

    create_table :stock_transfer_resolutions do |t|
      t.references :business,            null: false, foreign_key: true
      t.references :stock_transfer,      null: false, foreign_key: true
      t.references :stock_transfer_item, null: false, foreign_key: true
      t.references :resolved_by,         null: false, foreign_key: { to_table: :users }
      t.string   :kind, null: false
      t.decimal  :quantity, precision: 12, scale: 3, null: false
      t.text     :reason, null: false
      t.datetime :resolved_at, null: false
      t.date     :resolved_on, null: false
      t.datetime :created_at, null: false
      t.check_constraint "kind IN ('return_to_source', 'write_off')", name: "stock_transfer_resolutions_kind_valid"
      t.check_constraint "quantity > 0", name: "stock_transfer_resolutions_quantity_positive"
      t.check_constraint "btrim(reason) <> ''", name: "stock_transfer_resolutions_reason_present"
    end

    execute <<~SQL
      CREATE FUNCTION public.stock_transfer_ledgers_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is append-only (% refused)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'restrict_violation';
      END;
      $$;
    SQL
    %w[stock_transfer_receipts stock_transfer_receipt_lines stock_transfer_resolutions].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION public.stock_transfer_ledgers_append_only();
      SQL
    end
  end

  def down
    blockers = {
      "a transit warehouse"            => "SELECT 1 FROM warehouses WHERE kind = 'transit' LIMIT 1",
      "via-transit transfers"          => "SELECT 1 FROM stock_transfers WHERE posting_mode <> 'direct' LIMIT 1",
      "transfer receipts"              => "SELECT 1 FROM stock_transfer_receipts LIMIT 1",
      "transfer resolutions"           => "SELECT 1 FROM stock_transfer_resolutions LIMIT 1",
      "transit ledger movements"       => "SELECT 1 FROM inventory_movements WHERE reason IN (#{quoted(TRANSIT_REASONS + %w[transfer_return])}) LIMIT 1",
      "requested quantities"           => "SELECT 1 FROM stock_transfer_items WHERE requested_quantity IS NOT NULL LIMIT 1"
    }.select { |_, sql| select_value(sql) }.keys
    if blockers.any?
      raise ActiveRecord::IrreversibleMigration,
            "transit workflow data exists (#{blockers.join(', ')}); it cannot be rolled back without losing records"
    end

    %w[stock_transfer_receipts stock_transfer_receipt_lines stock_transfer_resolutions].each do |table|
      execute "DROP TRIGGER #{table}_append_only ON #{table}"
    end
    execute "DROP FUNCTION public.stock_transfer_ledgers_append_only()"
    drop_table :stock_transfer_resolutions
    drop_table :stock_transfer_receipt_lines
    drop_table :stock_transfer_receipts

    remove_check_constraint :stock_transfer_items, name: "stock_transfer_items_requested_quantity_positive"
    remove_column :stock_transfer_items, :requested_quantity

    remove_check_constraint :stock_transfers, name: "stock_transfers_receipt_recorded"
    remove_check_constraint :stock_transfers, name: "stock_transfers_dispatch_recorded"
    remove_check_constraint :stock_transfers, name: "stock_transfers_status_matches_posting_mode"
    remove_check_constraint :stock_transfers, name: "stock_transfers_posting_mode_valid"
    remove_check_constraint :stock_transfers, name: "stock_transfers_status_valid"
    add_check_constraint :stock_transfers, "status IN (#{quoted(OLD_STATUSES)})", name: "stock_transfers_status_valid"
    remove_index :stock_transfers, name: "index_stock_transfers_on_business_mode_status"
    remove_column :stock_transfers, :received_at
    remove_column :stock_transfers, :dispatched_on
    remove_reference :stock_transfers, :dispatched_by, foreign_key: { to_table: :users }, index: true
    remove_column :stock_transfers, :dispatched_at
    remove_column :stock_transfers, :posting_mode

    execute "DROP TRIGGER inventory_movements_transit_legs ON inventory_movements"
    execute "DROP FUNCTION public.inventory_movements_transit_legs()"
    OPERATIONAL_REFERENCES.each_key do |table|
      execute "DROP TRIGGER #{table}_operational_warehouse_only ON #{table}"
    end
    execute "DROP FUNCTION public.reject_transit_warehouse_reference()"

    remove_index :warehouses, name: "index_warehouses_one_transit_per_business"
    remove_check_constraint :warehouses, name: "warehouses_transit_always_active"
    remove_check_constraint :warehouses, name: "warehouses_kind_known"
    add_check_constraint :warehouses, "kind IS NULL OR kind IN ('central', 'branch')", name: "warehouses_kind_known"
  end

  private

  def quoted(values) = values.map { |v| "'#{v}'" }.join(", ")
end
