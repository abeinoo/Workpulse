class AddBranchToBiometricDevicesAndPunchLogs < ActiveRecord::Migration[8.1]
  # Cross-branch biometric attendance: a device is registered to the branch it
  # physically stands at, and every punch log keeps the branch its device had
  # when the punch was received — the actual branch of the punch, which may
  # differ from the branch of the employee's shift assignment
  # (attendance_records.branch_id, unchanged).
  #
  # Both nullable with no backfill: an existing device has no known branch (it
  # is never inferred from its name or location_note) and keeps accepting
  # punches, logged with branch_id NULL, until an admin assigns one. Existing
  # punch logs stay NULL — their branch was never recorded.
  #
  # Foreign keys without ON DELETE, like every other branch reference (BUG-026,
  # spec/models/branch_deletion_constraints_spec.rb): a branch with devices or
  # punch logs is refused by OrganizationAccess::DeleteBranch and deactivated
  # instead.
  #
  # Rollback drops both columns and their data: every device's branch and the
  # actual branch of every punch logged since deploy, which nothing else records.
  # Once punches have been received, roll the code back instead (the old code
  # ignores the columns) and keep the schema; never run db:rollback past this
  # version in production without first exporting
  # biometric_punch_logs (id, branch_id) and biometric_devices (id, branch_id).
  def change
    add_reference :biometric_devices,    :branch, foreign_key: true, index: true
    add_reference :biometric_punch_logs, :branch, foreign_key: true, index: true
  end
end
