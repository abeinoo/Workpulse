# Fills the two new columns for requests created before the warehouse/supplier
# refactor, so legacy requests read the same way as new ones. Only EMPTY new
# columns are written; the legacy purchase_requests.supplier_id and
# purchase_request_items.source_warehouse_id values are never changed.
#
#   - Each line inherits its request's supplier (a legacy request had exactly
#     one supplier, or none).
#   - A request gets a warehouse only when every one of its lines names the
#     same warehouse. Mixed or missing line warehouses leave it NULL — never a
#     guess. (A Goods Receipt from such a request still asks for a warehouse.)
#
# down is a no-op: the columns themselves are dropped by the previous
# migration's down, and nothing else was touched.
class BackfillPurchaseRequestItemSuppliersAndWarehouse < ActiveRecord::Migration[8.1]
  ITEM_SUPPLIER_SQL = <<~SQL.squish.freeze
    UPDATE purchase_request_items pri
       SET supplier_id = pr.supplier_id
      FROM purchase_requests pr
     WHERE pr.id = pri.purchase_request_id
       AND pr.supplier_id IS NOT NULL
       AND pri.supplier_id IS NULL
  SQL

  REQUEST_WAREHOUSE_SQL = <<~SQL.squish.freeze
    UPDATE purchase_requests pr
       SET warehouse_id = lines.warehouse_id
      FROM (
        SELECT purchase_request_id, MIN(source_warehouse_id) AS warehouse_id
          FROM purchase_request_items
         GROUP BY purchase_request_id
        HAVING COUNT(*) = COUNT(source_warehouse_id)
           AND COUNT(DISTINCT source_warehouse_id) = 1
      ) lines
     WHERE lines.purchase_request_id = pr.id
       AND pr.warehouse_id IS NULL
  SQL

  def up
    execute ITEM_SUPPLIER_SQL
    execute REQUEST_WAREHOUSE_SQL
  end

  def down; end
end
