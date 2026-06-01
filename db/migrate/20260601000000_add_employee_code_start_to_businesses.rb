class AddEmployeeCodeStartToBusinesses < ActiveRecord::Migration[8.1]
  def up
    # Configurable starting number for auto-generated employee codes.
    # Existing businesses default to 1; admins can raise it (e.g. 500) in settings.
    add_column :businesses, :employee_code_start, :integer,
               null: false, default: 1,
               comment: "starting number for auto-generated employee_code"

    # The per-business, case-insensitive unique index on users.employee_code
    # (index_users_on_business_id_and_lower_employee_code) already exists from
    # 20260519200000 and is the database-level guard against duplicate codes.
    # Re-create it defensively only if it is somehow missing.
    unless index_name_exists?(:users, "index_users_on_business_id_and_lower_employee_code")
      execute <<~SQL
        CREATE UNIQUE INDEX index_users_on_business_id_and_lower_employee_code
          ON users (business_id, lower(employee_code))
          WHERE employee_code IS NOT NULL
            AND employee_code <> ''
      SQL
    end
  end

  def down
    remove_column :businesses, :employee_code_start
  end
end
