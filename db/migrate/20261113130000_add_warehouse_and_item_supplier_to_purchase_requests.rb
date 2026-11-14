# Purchase Request warehouse/supplier refactor: the destination warehouse
# moves to the request (every line of a request goes to that one warehouse),
# the supplier moves to each line (one request may buy from several
# suppliers). Purely additive — the legacy purchase_requests.supplier_id and
# purchase_request_items.source_warehouse_id columns stay, untouched, for the
# requests created before this change.
#
# Idempotency: a request created from now on has no request-level supplier,
# and one batch key may create one request PER WAREHOUSE (Low Stock review).
# The old partial index allowed only ONE no-supplier request per key, so it is
# replaced by one on (idempotency_key, COALESCE(warehouse_id, 0)) over the
# same no-supplier rows. COALESCE keeps the old guarantee for a legacy
# no-supplier request without a warehouse (PostgreSQL 14 has no NULLS NOT
# DISTINCT). The (idempotency_key, supplier_id) index for legacy requests with
# a supplier is unchanged.
class AddWarehouseAndItemSupplierToPurchaseRequests < ActiveRecord::Migration[8.1]
  OLD_INDEX = "index_purchase_requests_on_idem_key_without_supplier".freeze
  NEW_INDEX = "index_purchase_requests_on_idem_key_warehouse_no_supplier".freeze

  def up
    add_reference :purchase_requests, :warehouse, foreign_key: true, null: true
    add_reference :purchase_request_items, :supplier, foreign_key: true, null: true

    remove_index :purchase_requests, name: OLD_INDEX
    add_index :purchase_requests, "idempotency_key, COALESCE(warehouse_id, 0)",
              unique: true,
              where:  "idempotency_key IS NOT NULL AND supplier_id IS NULL",
              name:   NEW_INDEX
  end

  def down
    remove_index :purchase_requests, name: NEW_INDEX
    # Fails loudly if a batch key already spans several warehouses.
    add_index :purchase_requests, :idempotency_key,
              unique: true,
              where:  "idempotency_key IS NOT NULL AND supplier_id IS NULL",
              name:   OLD_INDEX

    remove_reference :purchase_request_items, :supplier, foreign_key: true
    remove_reference :purchase_requests, :warehouse, foreign_key: true
  end
end
