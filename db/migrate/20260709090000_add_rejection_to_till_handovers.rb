class AddRejectionToTillHandovers < ActiveRecord::Migration[8.1]
  def change
    add_column :till_handovers, :rejected_at, :datetime

    add_reference :till_handovers, :rejected_by,
                  null:        true,
                  foreign_key: { to_table: :users },
                  index:       { name: "index_till_handovers_on_rejected_by_id" }

    add_column :till_handovers, :rejection_reason, :text
    add_column :till_handovers, :cancellation_reason, :text
  end
end
