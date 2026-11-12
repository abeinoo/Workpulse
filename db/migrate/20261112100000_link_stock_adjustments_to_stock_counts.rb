# Stock count lifecycle repair — adjustment ⇄ count link.
#
# A stock count may now be approved, reopened (its adjustment voided) and
# approved again, so it owns MANY adjustments over its life, of which at most
# ONE is active (not voided). The link therefore moves to the adjustment side:
#
#   stock_adjustments.stock_count_id  (FK, restrict)
#   index_stock_adjustments_one_active_per_stock_count — UNIQUE (stock_count_id)
#     WHERE stock_count_id IS NOT NULL AND voided_at IS NULL
#
# The partial unique index is the database backstop against a duplicate
# approval: two active adjustments for one count can never be committed.
#
# Backfill: an adjustment is linked to a count only when the relationship is
# unambiguous — the count's legacy stock_counts.stock_adjustment_id names it,
# no other count names it, it is a stock_count-reason adjustment, and business
# and warehouse match. Anything else (e.g. manual adjustments that were saved
# with the "stock_count" reason) stays unlinked; the migration prints how many.
#
# stock_counts.stock_adjustment_id is kept, untouched, as historical data; the
# application no longer writes it. Reversible: down drops the new column and
# indexes (the legacy column still holds every pre-existing link).
class LinkStockAdjustmentsToStockCounts < ActiveRecord::Migration[8.1]
  # Unambiguous links only (see header). Idempotent: rows already linked are
  # left alone. Exercised by spec/db/link_stock_adjustments_to_stock_counts_spec.rb.
  BACKFILL_SQL = <<~SQL.squish.freeze
    UPDATE stock_adjustments sa
       SET stock_count_id = sc.id
      FROM stock_counts sc
     WHERE sc.stock_adjustment_id = sa.id
       AND sa.stock_count_id IS NULL
       AND sa.reason = 'stock_count'
       AND sa.business_id = sc.business_id
       AND sa.warehouse_id = sc.warehouse_id
       AND (SELECT COUNT(*) FROM stock_counts other WHERE other.stock_adjustment_id = sa.id) = 1
  SQL

  def up
    add_reference :stock_adjustments, :stock_count, null: true, index: true,
                  foreign_key: { on_delete: :restrict }

    linked = execute(BACKFILL_SQL).cmd_tuples

    unlinked = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM stock_adjustments
       WHERE reason = 'stock_count' AND stock_count_id IS NULL
    SQL
    say "linked #{linked} stock-count adjustment(s); #{unlinked} stock_count-reason adjustment(s) left unlinked (no unambiguous count)"

    add_index :stock_adjustments, :stock_count_id,
              unique: true, where: "stock_count_id IS NOT NULL AND voided_at IS NULL",
              name: "index_stock_adjustments_one_active_per_stock_count"
  end

  def down
    remove_index :stock_adjustments, name: "index_stock_adjustments_one_active_per_stock_count"
    remove_reference :stock_adjustments, :stock_count, foreign_key: true, index: true
  end
end
