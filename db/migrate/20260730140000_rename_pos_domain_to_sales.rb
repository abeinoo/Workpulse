class RenamePosDomainToSales < ActiveRecord::Migration[8.1]
  # Permanent domain rename: this module imports Sales transactions exported
  # from Fresha, not point-of-sale device transactions. Renames the tables/
  # column to match the SalesImport/SalesTransaction models, and backfills
  # the two permission strings so existing role grants keep working.
  #
  # No explicit rename_index calls here: rename_table/rename_column already
  # rename any index following Rails' default naming convention as part of
  # the same statement, so doing it again explicitly would try to rename an
  # index that's already been renamed and raise PG::UndefinedTable.
  OLD_TO_NEW_PERMISSIONS = {
    "view_pos_transactions_verification" => "view_sales_transactions_verification",
    "manage_pos_import"                  => "manage_sales_import"
  }.freeze

  def up
    rename_table :pos_imports, :sales_imports
    rename_table :pos_transactions, :sales_transactions
    rename_column :sales_transactions, :pos_import_id, :sales_import_id

    backfill_permissions(OLD_TO_NEW_PERMISSIONS)
  end

  def down
    backfill_permissions(OLD_TO_NEW_PERMISSIONS.invert)

    rename_column :sales_transactions, :sales_import_id, :pos_import_id
    rename_table :sales_transactions, :pos_transactions
    rename_table :sales_imports, :pos_imports
  end

  private

  def backfill_permissions(mapping)
    PermissionRole.reset_column_information

    PermissionRole.find_each do |role|
      permissions = Array(role.permissions)
      scopes      = (role.permission_scopes || {}).dup
      changed     = false

      mapping.each do |old_name, new_name|
        if permissions.include?(old_name)
          permissions = (permissions - [ old_name ]) + [ new_name ]
          changed = true
        end

        if scopes.key?(old_name)
          scopes[new_name] = scopes.delete(old_name)
          changed = true
        end
      end

      next unless changed

      role.update_columns(permissions: permissions, permission_scopes: scopes)
      say "Renamed POS permissions on '#{role.name}' (id=#{role.id})"
    end
  end
end
