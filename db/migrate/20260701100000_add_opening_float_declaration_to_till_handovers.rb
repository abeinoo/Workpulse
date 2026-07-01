class AddOpeningFloatDeclarationToTillHandovers < ActiveRecord::Migration[8.0]
  def change
    add_column :till_handovers, :opening_float_declaration, :boolean, null: false, default: false
  end
end
