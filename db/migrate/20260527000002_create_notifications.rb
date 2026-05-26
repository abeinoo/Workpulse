class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :user,       null: false, foreign_key: true
      t.references :notifiable, polymorphic: true
      t.string  :event_type, null: false
      t.string  :title,      null: false
      t.text    :body
      t.string  :severity,   null: false, default: "info"
      t.jsonb   :data,       null: false, default: {}
      t.datetime :read_at
      t.timestamps
    end

    add_index :notifications, [ :user_id, :read_at ]
    add_index :notifications, [ :user_id, :created_at ]
    add_index :notifications, :event_type
  end
end
