class AddBranchIdSnapshotToPerformanceReviews < ActiveRecord::Migration[8.1]
  def change
    # Captured once at review creation time (see PerformanceReview#snapshot_branch_and_department)
    # so later employee transfers never rewrite historical analytics. Nullable: existing
    # rows predate the snapshot and are handled nil-safely everywhere this is read.
    add_reference :performance_reviews, :branch, null: true, foreign_key: true, index: true
    add_index :performance_reviews, [ :business_id, :branch_id ]
  end
end
