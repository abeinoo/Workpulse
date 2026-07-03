class AddCorrectionFieldsToTillHandovers < ActiveRecord::Migration[8.1]
  def change
    add_column :till_handovers, :superseded_at, :datetime
    add_column :till_handovers, :superseded_by_id, :bigint
    add_column :till_handovers, :correction_reason, :text
    add_column :till_handovers, :corrects_handover_id, :bigint

    add_index :till_handovers, :superseded_by_id
    add_index :till_handovers, :corrects_handover_id

    add_foreign_key :till_handovers, :users, column: :superseded_by_id
    add_foreign_key :till_handovers, :till_handovers, column: :corrects_handover_id
  end
end
