# Salary Payment Hold (Attendance & Payroll): a hold blocks PAYMENT of an
# employee's salary, never its calculation.
#
# salary_payment_holds — the hold itself. Never deleted; released once
# (released_at / released_by_id / release_reason set together). At most one
# active (unreleased) hold per employee, enforced by a partial unique index.
#
# salary_payment_withholdings — one row per payroll entry whose payment was
# withheld when its period was marked paid. Stores no amount: the held amount is
# the entry's net_salary, frozen once the period is finalized. Disbursed once
# (after the hold is released), or voided when the paid period is reopened; at
# most one live (not voided) withholding per entry.
class CreateSalaryPaymentHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :salary_payment_holds do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :user,        null: false, foreign_key: true
      t.date       :effective_from, null: false
      t.string     :reason,      null: false
      t.text       :notes
      t.references :created_by,  null: false, foreign_key: { to_table: :users }
      t.datetime   :released_at
      t.references :released_by, foreign_key: { to_table: :users }
      t.text       :release_reason
      t.timestamps
    end
    add_index :salary_payment_holds, :user_id, unique: true, where: "released_at IS NULL",
              name: "index_salary_payment_holds_one_active_per_user"
    add_check_constraint :salary_payment_holds,
                         "(released_at IS NULL) = (released_by_id IS NULL)",
                         name: "salary_payment_holds_release_complete"
    add_check_constraint :salary_payment_holds,
                         "reason IN ('missing_documents', 'incomplete_hiring_paperwork', 'pending_hr_review', " \
                         "'administrative_issue', 'other')",
                         name: "salary_payment_holds_reason_known"

    create_table :salary_payment_withholdings do |t|
      t.references :business,            null: false, foreign_key: true
      t.references :payroll_entry,       null: false, foreign_key: true
      t.references :salary_payment_hold, null: false, foreign_key: true
      t.datetime   :withheld_at,         null: false
      t.references :withheld_by,         null: false, foreign_key: { to_table: :users }
      t.datetime   :disbursed_at
      t.references :disbursed_by,        foreign_key: { to_table: :users }
      t.text       :disbursement_note
      t.datetime   :voided_at
      t.references :voided_by,           foreign_key: { to_table: :users }
      t.text       :void_reason
      t.timestamps
    end
    add_index :salary_payment_withholdings, :payroll_entry_id, unique: true, where: "voided_at IS NULL",
              name: "index_salary_payment_withholdings_one_live_per_entry"
    add_check_constraint :salary_payment_withholdings,
                         "(disbursed_at IS NULL) = (disbursed_by_id IS NULL)",
                         name: "salary_payment_withholdings_disbursement_complete"
    add_check_constraint :salary_payment_withholdings,
                         "(voided_at IS NULL) = (voided_by_id IS NULL)",
                         name: "salary_payment_withholdings_void_complete"
    add_check_constraint :salary_payment_withholdings,
                         "disbursed_at IS NULL OR voided_at IS NULL",
                         name: "salary_payment_withholdings_not_disbursed_and_voided"
  end
end
