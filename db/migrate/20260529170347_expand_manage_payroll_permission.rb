class ExpandManagePayrollPermission < ActiveRecord::Migration[8.1]
  # Maps the legacy coarse `manage_payroll` permission onto the granular
  # action-specific replacements. Permissions that did not previously exist
  # (`complete_branch_review`, `reopen_payroll`, `view_payroll_audit_log`)
  # are intentionally NOT auto-granted — they require explicit assignment.
  REPLACEMENTS = %w[
    create_payroll
    regenerate_payroll
    submit_payroll_review
    approve_payroll_items
    pay_payroll
    delete_payroll
  ].freeze

  def up
    PermissionRole.find_each do |role|
      perms = Array(role.permissions)
      next unless perms.include?("manage_payroll")

      new_perms = (perms - ["manage_payroll"] + REPLACEMENTS).uniq

      # Preserve the manage_payroll scope across all replacement permissions.
      scopes       = role.permission_scopes || {}
      legacy_scope = scopes["manage_payroll"]
      new_scopes   = scopes.except("manage_payroll")
      if legacy_scope.present?
        REPLACEMENTS.each { |perm| new_scopes[perm] ||= legacy_scope }
      end

      role.update_columns(
        permissions:       new_perms,
        permission_scopes: new_scopes,
        updated_at:        Time.current
      )
    end
  end

  def down
    PermissionRole.find_each do |role|
      perms = Array(role.permissions)
      next if (perms & REPLACEMENTS).empty?

      new_perms = (perms - REPLACEMENTS + ["manage_payroll"]).uniq

      scopes       = role.permission_scopes || {}
      legacy_scope = REPLACEMENTS.lazy.map { |p| scopes[p] }.detect(&:present?)
      new_scopes   = scopes.except(*REPLACEMENTS)
      new_scopes["manage_payroll"] = legacy_scope if legacy_scope.present?

      role.update_columns(
        permissions:       new_perms,
        permission_scopes: new_scopes,
        updated_at:        Time.current
      )
    end
  end
end
