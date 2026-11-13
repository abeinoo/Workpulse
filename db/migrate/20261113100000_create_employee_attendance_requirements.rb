# R3.2 (roadmap revision 19, §2 W, §8; G1): the effective-dated attendance
# requirement history of each employee — Workforce-owned, the single source of
# truth for "must this employee attend on date d" (A3, L4). The value in force is
# derived on read (OD-4): no users.requires_attendance cache, no job.
#
#   status  required / not_required / not_reviewed; not_reviewed only from the
#           R3.3 backfill (L11) — HR and employee creation never write it
#   source  creation / hr_change / backfill; effective_date_basis only on
#           backfill rows (L12)
#
# No unique (user_id, effective_from): rows on the same date are ordered by
# (effective_from, id) and the latest wins (OD-15 T3). Append-only (OD-15 T2): a
# trigger refuses UPDATE and DELETE; TRUNCATE (test cleanup) is not blocked. The
# user foreign key restricts deletion, so OrganizationAccess::DeleteUser refuses
# an employee with history (:linked_records), as for other history.
#
# Rollback refuses while any row exists: the history is never dropped once written.
class CreateEmployeeAttendanceRequirements < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_attendance_requirements do |t|
      t.references :business,   null: false, foreign_key: true, index: true
      t.references :user,       null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string     :status,     null: false
      t.date       :effective_from, null: false
      t.string     :source,     null: false
      t.string     :effective_date_basis
      t.text       :reason
      t.references :changed_by, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime   :created_at, null: false
    end

    add_index :employee_attendance_requirements, %i[user_id effective_from id],
              name: "index_employee_attendance_requirements_on_user_timeline"

    add_check_constraint :employee_attendance_requirements,
                         "status IN ('required', 'not_required', 'not_reviewed')",
                         name: "employee_attendance_requirements_status"
    add_check_constraint :employee_attendance_requirements,
                         "source IN ('creation', 'hr_change', 'backfill')",
                         name: "employee_attendance_requirements_source"
    add_check_constraint :employee_attendance_requirements,
                         "status <> 'not_reviewed' OR source = 'backfill'",
                         name: "employee_attendance_requirements_not_reviewed_backfill_only"
    add_check_constraint :employee_attendance_requirements,
                         "(source = 'backfill') OR effective_date_basis IS NULL",
                         name: "employee_attendance_requirements_basis_backfill_only"

    execute <<~SQL
      CREATE FUNCTION employee_attendance_requirements_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'employee_attendance_requirements is append-only' USING ERRCODE = 'restrict_violation';
      END;
      $$;

      CREATE TRIGGER employee_attendance_requirements_append_only
        BEFORE UPDATE OR DELETE ON employee_attendance_requirements
        FOR EACH ROW EXECUTE FUNCTION employee_attendance_requirements_append_only();
    SQL
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM employee_attendance_requirements)")
      raise ActiveRecord::IrreversibleMigration,
            "employee_attendance_requirements has rows: the requirement history is never dropped"
    end

    execute <<~SQL
      DROP TRIGGER IF EXISTS employee_attendance_requirements_append_only ON employee_attendance_requirements;
      DROP FUNCTION IF EXISTS employee_attendance_requirements_append_only();
    SQL
    drop_table :employee_attendance_requirements
  end
end
