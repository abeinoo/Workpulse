class BackfillViewAdjustmentsPermission < ActiveRecord::Migration[8.0]
  def up
    # Any role that can manage or approve adjustments must now have view_adjustments
    # (previously these permissions required view_payroll, which is being decoupled).
    PermissionRole.find_each do |role|
      perms = Array(role.permissions)
      next unless perms.intersect?(%w[manage_adjustments approve_adjustments edit_approved_adjustments])
      next if perms.include?("view_adjustments")

      role.update_columns(permissions: perms | ["view_adjustments"])
    end
  end

  def down
    # Intentionally not removing view_adjustments on rollback: some roles may have
    # acquired it independently after this migration ran.
  end
end
