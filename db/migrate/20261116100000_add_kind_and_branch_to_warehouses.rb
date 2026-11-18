# Warehouse Architecture — PR 1 (schema & models only).
#
# warehouses.kind      — 'central' | 'branch'. NULL = not yet classified: every
#                        existing warehouse keeps NULL here. Classification is
#                        an explicit, audited, human decision made in a later
#                        stage — never inferred by this migration (not even
#                        from the warehouse name).
# warehouses.branch_id — the owning branch of a 'branch' warehouse; NULL for a
#                        central or unclassified warehouse. No ON DELETE: a
#                        branch that owns a warehouse can never be deleted out
#                        from under it.
#
# Database invariants:
#   * kind is NULL or one of the known values;
#   * a branch warehouse has a branch, and nothing else has one
#     (IS NOT DISTINCT FROM keeps a NULL kind on the "no branch" side);
#   * at most one warehouse per branch (partial unique index) — together with
#     the CHECK, a branch never has more than one branch warehouse.
#
# "Warehouse and branch belong to the same business" is enforced by
# Warehouse#branch_in_same_business, not here: a composite foreign key would
# need a new unique index on branches (an Organization & Access table) and a
# trigger would have Inventory SQL read an OA table. Every other Inventory model
# enforces business consistency the same way (IP-1).
#
# Additive only: no row is written, no stock or movement is touched. Reversible.
class AddKindAndBranchToWarehouses < ActiveRecord::Migration[8.1]
  def change
    add_column :warehouses, :kind, :string
    add_reference :warehouses, :branch, foreign_key: true, index: false

    add_index :warehouses, :branch_id, unique: true, where: "branch_id IS NOT NULL",
              name: "index_warehouses_one_per_branch"
    add_check_constraint :warehouses,
                         "kind IS NULL OR kind IN ('central', 'branch')",
                         name: "warehouses_kind_known"
    add_check_constraint :warehouses,
                         "(kind IS NOT DISTINCT FROM 'branch') = (branch_id IS NOT NULL)",
                         name: "warehouses_branch_only_for_branch_kind"
  end
end
