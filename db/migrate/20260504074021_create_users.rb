class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :otp_code
      t.datetime :otp_sent_at

      t.timestamps
    end
  end
end
