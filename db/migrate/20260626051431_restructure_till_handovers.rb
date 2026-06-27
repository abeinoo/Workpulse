class RestructureTillHandovers < ActiveRecord::Migration[8.1]
  def up
    # Drop all old data and indexes first — this is a dev environment rewrite.
    # till_handover_lines is replaced by till_handover_amounts.
    remove_foreign_key :till_handover_lines, :payment_methods
    remove_foreign_key :till_handover_lines, :till_handovers
    drop_table :till_handover_lines

    # Drop deposits first (FK to till_handovers, will be re-added pointing to till_sessions)
    remove_foreign_key :till_deposits, :till_handovers
    remove_index  :till_deposits, name: "idx_till_deposits_handover_method"
    remove_index  :till_deposits, name: "index_till_deposits_on_till_handover_id"
    remove_column :till_deposits, :till_handover_id

    # Remove old till_handovers indexes and columns
    remove_index :till_handovers, name: "idx_till_handovers_branch_date"                rescue nil
    remove_index :till_handovers, name: "idx_till_handovers_unique_chain_head"          rescue nil
    remove_index :till_handovers, name: "idx_till_handovers_unique_successor"           rescue nil
    remove_index :till_handovers, name: "idx_till_handovers_from_user_date"             rescue nil
    remove_index :till_handovers, name: "index_till_handovers_on_branch_id"             rescue nil
    remove_index :till_handovers, name: "index_till_handovers_on_business_id"           rescue nil
    remove_index :till_handovers, name: "index_till_handovers_on_from_user_id"          rescue nil
    remove_index :till_handovers, name: "index_till_handovers_on_to_user_id"            rescue nil

    remove_foreign_key :till_handovers, :branches
    remove_foreign_key :till_handovers, :businesses
    remove_foreign_key :till_handovers, :till_handovers               rescue nil

    remove_column :till_handovers, :branch_id
    remove_column :till_handovers, :business_id
    remove_column :till_handovers, :business_date
    remove_column :till_handovers, :handover_type
    remove_column :till_handovers, :previous_handover_id

    # Add new columns
    add_reference :till_handovers, :till_session,
                  null: false,
                  foreign_key: true,
                  index: true

    add_column :till_handovers, :float_amount,     :decimal, precision: 12, scale: 2
    add_column :till_handovers, :from_notes,       :text
    add_column :till_handovers, :accepted_notes,   :text

    # Index for common queries: all handovers for a session
    add_index :till_handovers, [ :till_session_id, :accepted_at ],
              name: "idx_till_handovers_session_accepted"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
