class AddProfileFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :job_title,        :string
    add_column :users, :department,       :string
    add_column :users, :hire_date,        :date
    add_column :users, :employment_type,  :string

    add_index :users, [:business_id, :department]
  end
end
