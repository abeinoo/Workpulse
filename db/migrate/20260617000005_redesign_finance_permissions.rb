class RedesignFinancePermissions < ActiveRecord::Migration[8.0]
  def up
    # Rename view_custody → view_employee_balances in permissions JSONB array.
    execute <<~SQL
      UPDATE permission_roles
      SET permissions = (
        SELECT jsonb_agg(
          CASE elem::text
          WHEN '"view_custody"' THEN '"view_employee_balances"'::jsonb
          ELSE elem
          END
        )
        FROM jsonb_array_elements(permissions) AS elem
      )
      WHERE permissions @> '["view_custody"]'::jsonb;
    SQL

    # Rename manage_custody → manage_employee_balances in permissions JSONB array.
    execute <<~SQL
      UPDATE permission_roles
      SET permissions = (
        SELECT jsonb_agg(
          CASE elem::text
          WHEN '"manage_custody"' THEN '"manage_employee_balances"'::jsonb
          ELSE elem
          END
        )
        FROM jsonb_array_elements(permissions) AS elem
      )
      WHERE permissions @> '["manage_custody"]'::jsonb;
    SQL

    # Rename keys inside the permission_scopes JSONB object.
    execute <<~SQL
      UPDATE permission_roles
      SET permission_scopes =
        (permission_scopes - 'view_custody') ||
        jsonb_build_object('view_employee_balances', permission_scopes->'view_custody')
      WHERE permission_scopes ? 'view_custody';
    SQL

    execute <<~SQL
      UPDATE permission_roles
      SET permission_scopes =
        (permission_scopes - 'manage_custody') ||
        jsonb_build_object('manage_employee_balances', permission_scopes->'manage_custody')
      WHERE permission_scopes ? 'manage_custody';
    SQL

    # Add role_type column for pre-defined role archetypes.
    add_column :permission_roles, :role_type, :string
  end

  def down
    remove_column :permission_roles, :role_type

    execute <<~SQL
      UPDATE permission_roles
      SET permissions = (
        SELECT jsonb_agg(
          CASE elem::text
          WHEN '"view_employee_balances"' THEN '"view_custody"'::jsonb
          ELSE elem
          END
        )
        FROM jsonb_array_elements(permissions) AS elem
      )
      WHERE permissions @> '["view_employee_balances"]'::jsonb;
    SQL

    execute <<~SQL
      UPDATE permission_roles
      SET permissions = (
        SELECT jsonb_agg(
          CASE elem::text
          WHEN '"manage_employee_balances"' THEN '"manage_custody"'::jsonb
          ELSE elem
          END
        )
        FROM jsonb_array_elements(permissions) AS elem
      )
      WHERE permissions @> '["manage_employee_balances"]'::jsonb;
    SQL

    execute <<~SQL
      UPDATE permission_roles
      SET permission_scopes =
        (permission_scopes - 'view_employee_balances') ||
        jsonb_build_object('view_custody', permission_scopes->'view_employee_balances')
      WHERE permission_scopes ? 'view_employee_balances';
    SQL

    execute <<~SQL
      UPDATE permission_roles
      SET permission_scopes =
        (permission_scopes - 'manage_employee_balances') ||
        jsonb_build_object('manage_custody', permission_scopes->'manage_employee_balances')
      WHERE permission_scopes ? 'manage_employee_balances';
    SQL
  end
end
