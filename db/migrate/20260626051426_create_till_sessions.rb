class CreateTillSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :till_sessions do |t|
      t.references :business,        null: false, foreign_key: true
      t.references :branch,          null: false, foreign_key: true
      t.string     :state,           null: false, default: "open"
      t.references :current_holder,  null: true,  foreign_key: { to_table: :users }
      t.references :depositor,       null: true,  foreign_key: { to_table: :users }
      t.references :closed_by,       null: true,  foreign_key: { to_table: :users }
      t.date       :fresha_date
      t.datetime   :opened_at,       null: false
      t.datetime   :closed_at
      t.datetime   :deposited_at
      t.timestamps
    end

    # Enforce: at most one open session per branch at any time.
    add_index :till_sessions, :branch_id,
              unique: true,
              where:  "state = 'open'",
              name:   "idx_till_sessions_one_open_per_branch"
  end
end
