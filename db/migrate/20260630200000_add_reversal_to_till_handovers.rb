class AddReversalToTillHandovers < ActiveRecord::Migration[8.0]
  def change
    add_column :till_handovers, :reversed_at,              :datetime
    add_column :till_handovers, :reversed_by_id,           :bigint
    add_column :till_handovers, :reversal_of_handover_id,  :bigint
    add_column :till_handovers, :reversal_reason,          :text

    add_foreign_key :till_handovers, :users,          column: :reversed_by_id
    add_foreign_key :till_handovers, :till_handovers, column: :reversal_of_handover_id

    add_index :till_handovers, :reversed_by_id,          name: "index_till_handovers_on_reversed_by_id"
    add_index :till_handovers, :reversal_of_handover_id, name: "index_till_handovers_on_reversal_of_handover_id"

    # One accepted handover per sender per DR while receiver hasn't started working
    # is enforced in the service layer.  DB prevents the narrower invariant:
    # a handover may be reversed at most once.
    add_index :till_handovers, :reversal_of_handover_id,
              unique: true,
              where:  "reversal_of_handover_id IS NOT NULL",
              name:   "idx_till_handovers_one_reversal_per_original"
  end
end
