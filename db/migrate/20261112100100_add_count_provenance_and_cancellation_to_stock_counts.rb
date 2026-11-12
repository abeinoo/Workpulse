# Stock count lifecycle repair — per-product count provenance and cancellation.
#
# stock_count_items:
#   counted_at              — when THIS product's physical quantity was entered
#                             (NULL for system-derived rows and for quantities
#                             entered before this migration: no timestamp is
#                             invented for them).
#   baseline_at             — when system_quantity was read from the ledger: the
#                             physical count time, or the completion cutoff for
#                             a system-derived row.
#   quantity_source         — 'physical' | 'system'. NULL = not counted, or a
#                             legacy quantity with no trustworthy count time.
#   legacy_counted_quantity — the pre-upgrade, unverified quantity, preserved
#                             when a recount or completion replaces it.
#
# stock_counts: cancelled_at / cancelled_by_id / cancel_reason for the new
# terminal "cancelled" status (a reopened count that once posted stock can be
# cancelled but never hard-deleted).
#
# Additive only: no existing row is rewritten. Existing counted quantities keep
# quantity_source NULL, which is exactly how the application recognises a
# legacy, unverified quantity. Reversible.
class AddCountProvenanceAndCancellationToStockCounts < ActiveRecord::Migration[8.1]
  def change
    change_table :stock_count_items, bulk: true do |t|
      t.datetime :counted_at
      t.datetime :baseline_at
      t.string   :quantity_source
      t.decimal  :legacy_counted_quantity, precision: 12, scale: 3
    end
    add_check_constraint :stock_count_items,
                         "quantity_source IS NULL OR quantity_source IN ('physical', 'system')",
                         name: "stock_count_items_quantity_source_check"

    change_table :stock_counts, bulk: true do |t|
      t.datetime   :cancelled_at
      t.references :cancelled_by, foreign_key: { to_table: :users }, index: true
      t.text       :cancel_reason
    end
  end
end
