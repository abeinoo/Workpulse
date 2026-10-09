# A Purchase Request says what to buy, not necessarily who from: it may be
# created, submitted, approved and received without a supplier (the actual
# supplier of each purchase is recorded on its Goods Receipt).
#
# The existing (idempotency_key, supplier_id) unique index can't protect a
# no-supplier request (NULLs are distinct in a unique index), so a second
# partial index covers at most ONE no-supplier request per batch key.
class MakePurchaseRequestSupplierOptional < ActiveRecord::Migration[8.1]
  def up
    change_column_null :purchase_requests, :supplier_id, true
    add_index :purchase_requests, :idempotency_key,
              unique: true,
              where:  "idempotency_key IS NOT NULL AND supplier_id IS NULL",
              name:   "index_purchase_requests_on_idem_key_without_supplier"
  end

  def down
    remove_index :purchase_requests, name: "index_purchase_requests_on_idem_key_without_supplier"
    # Fails loudly if any no-supplier request exists — assign suppliers first.
    change_column_null :purchase_requests, :supplier_id, false
  end
end
