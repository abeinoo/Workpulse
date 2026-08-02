class CreateSolidCableTables < ActiveRecord::Migration[8.1]
  # See 20260731140000_create_solid_queue_tables.rb for the full rationale —
  # same fix, applied to the `cable` role. Guarded no-op wherever the table
  # already exists (every current environment); creates it for a fresh database.
  def change
    return if table_exists?(:solid_cable_messages)

    create_table :solid_cable_messages do |t|
      t.binary "channel", limit: 1024, null: false
      t.binary "payload", limit: 536870912, null: false
      t.datetime "created_at", null: false
      t.integer "channel_hash", limit: 8, null: false
      t.index [ "channel" ], name: "index_solid_cable_messages_on_channel"
      t.index [ "channel_hash" ], name: "index_solid_cable_messages_on_channel_hash"
      t.index [ "created_at" ], name: "index_solid_cable_messages_on_created_at"
    end
  end
end
