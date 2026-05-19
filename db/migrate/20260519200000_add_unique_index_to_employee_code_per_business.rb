class AddUniqueIndexToEmployeeCodePerBusiness < ActiveRecord::Migration[8.0]
  def up
    # Drop any pre-existing loose unique index on employee_code alone
    remove_index :users, :employee_code if index_exists?(:users, :employee_code)

    # Functional unique index: case-insensitive uniqueness scoped to business.
    # Partial WHERE clause excludes NULL and blank values so employees without
    # an employee_code don't collide.
    execute <<~SQL
      CREATE UNIQUE INDEX index_users_on_business_id_and_lower_employee_code
        ON users (business_id, lower(employee_code))
        WHERE employee_code IS NOT NULL
          AND employee_code <> ''
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS index_users_on_business_id_and_lower_employee_code"
  end
end
