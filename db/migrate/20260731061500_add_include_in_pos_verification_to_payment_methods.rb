class AddIncludeInPosVerificationToPaymentMethods < ActiveRecord::Migration[8.1]
  def up
    add_column :payment_methods, :include_in_pos_verification, :boolean, default: false, null: false

    execute <<~SQL
      UPDATE payment_methods
      SET include_in_pos_verification = true
      WHERE lower(name) = 'visa' OR name_ar = 'فيزا'
    SQL
  end

  def down
    remove_column :payment_methods, :include_in_pos_verification
  end
end
