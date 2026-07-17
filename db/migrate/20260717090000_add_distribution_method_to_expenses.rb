class AddDistributionMethodToExpenses < ActiveRecord::Migration[8.1]
  def change
    add_column :expenses, :distribution_method, :string
  end
end
