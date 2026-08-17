class AddCoverageFieldsToShiftAssignments < ActiveRecord::Migration[8.1]
  def change
    # "regular" (default) vs "temporary_coverage" — explicit, stored intent
    # instead of the pre-existing inferred `effective_to.present? ||
    # source_template_id.present?` heuristic used elsewhere for filtering.
    # Existing rows all default to "regular"; nothing else changes.
    add_column :shift_assignments, :assignment_kind, :string, null: false, default: "regular"

    # Coverage reason (e.g. "Covering another employee's absence"). Required
    # only for temporary_coverage assignments — enforced at the model layer.
    add_column :shift_assignments, :reason, :text

    add_index :shift_assignments, :assignment_kind
  end
end
