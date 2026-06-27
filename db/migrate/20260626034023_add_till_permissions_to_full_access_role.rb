class AddTillPermissionsToFullAccessRole < ActiveRecord::Migration[8.1]
  # Permissions that broad operational roles should have for the till module.
  FULL_ACCESS_TILL = %w[
    create_shift_closing
    accept_shift_handover
    create_till_deposit
    view_daily_reconciliation
    verify_daily_reconciliation
    void_till_deposit
    view_finance_dashboard
    manage_payment_methods
  ].freeze

  # Permissions suitable for read-only roles.
  VIEW_ONLY_TILL = %w[
    view_daily_reconciliation
  ].freeze

  def up
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)

      # A role is "full access" if it can manage shifts; "view only" if it can
      # only view them. Other roles (single-purpose, custom) are left untouched.
      to_add =
        if (existing & %w[manage_shifts assign_shifts]).any?
          FULL_ACCESS_TILL - existing
        elsif existing.include?("view_shifts") && (existing & %w[manage_shifts assign_shifts]).empty?
          VIEW_ONLY_TILL - existing
        else
          []
        end

      next if to_add.empty?

      role.update_columns(permissions: existing + to_add)
      say "Added #{to_add.join(', ')} to '#{role.name}' (id=#{role.id})"
    end
  end

  def down
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)

      to_remove =
        if (existing & %w[manage_shifts assign_shifts]).any?
          FULL_ACCESS_TILL
        elsif existing.include?("view_shifts") && (existing & %w[manage_shifts assign_shifts]).empty?
          VIEW_ONLY_TILL
        else
          []
        end

      next if to_remove.empty?

      role.update_columns(permissions: existing - to_remove)
    end
  end
end
