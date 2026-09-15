class BackfillRecordExpensePaymentsPermission < ActiveRecord::Migration[8.0]
  def up
    # Anyone who could already approve expenses (and, until now, trigger the
    # single full custody deduction on approval) should also be able to record
    # the new manual partial payments — same trust level, same workflow.
    PermissionRole.find_each do |role|
      perms = Array(role.permissions)
      next unless perms.include?("approve_expenses")
      next if perms.include?("record_expense_payments")

      role.update_columns(permissions: perms | [ "record_expense_payments" ])
    end
  end

  def down
    # Intentionally not removing record_expense_payments on rollback: some
    # roles may have acquired it independently after this migration ran.
  end
end
