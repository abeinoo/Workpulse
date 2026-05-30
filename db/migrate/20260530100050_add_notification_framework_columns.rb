class AddNotificationFrameworkColumns < ActiveRecord::Migration[8.1]
  def change
    # Category powers the notification-center filters (attendance / leave /
    # payroll / approvals / system). Backfilled from event_type below.
    add_column :notifications, :category, :string
    add_index  :notifications, [ :user_id, :category ]

    # Per-user, per-category opt in/out. Empty hash means "all enabled".
    add_column :users, :notification_preferences, :jsonb, default: {}, null: false

    # Backfill category for existing rows from their event_type prefix.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE notifications SET category = 'payroll'
            WHERE event_type LIKE 'payroll%' OR event_type LIKE 'adjustment%' OR event_type LIKE 'line_item%';
          UPDATE notifications SET category = 'attendance'
            WHERE event_type LIKE 'attendance%';
          UPDATE notifications SET category = 'approvals'
            WHERE event_type LIKE 'employee_request%';
          UPDATE notifications SET category = 'system'
            WHERE category IS NULL;
        SQL
      end
    end
  end
end
