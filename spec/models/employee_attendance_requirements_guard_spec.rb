require "rails_helper"
require Rails.root.join("db/migrate/20261113100000_create_employee_attendance_requirements")
require Rails.root.join("db/migrate/20261113100100_add_employment_ended_on_to_users")

# R3.2 G1: database-level protection of the attendance requirement history
# (OD-15 T2) and the rollback guards of its migrations. Every example bypasses
# the model — update_all / delete_all, raw SQL — so only PostgreSQL's trigger and
# constraints are tested. Each refused statement runs in its own savepoint.
RSpec.describe "Employee attendance requirement database guards" do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let!(:row)     { create(:employee_attendance_requirement, user: employee) }
  let(:rows)     { EmployeeAttendanceRequirement.where(id: row.id) }
  let(:conn)     { ActiveRecord::Base.connection }

  def refused(pattern)
    expect { ActiveRecord::Base.transaction(requires_new: true) { yield } }
      .to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def insert(**columns)
    values = { business_id: business.id, user_id: employee.id, changed_by_id: employee.id, status: "required",
               source: "creation", effective_from: "2026-02-01", created_at: Time.current }.merge(columns)
    conn.execute(<<~SQL)
      INSERT INTO employee_attendance_requirements (#{values.keys.join(', ')})
      VALUES (#{values.values.map { |value| conn.quote(value) }.join(', ')})
    SQL
  end

  it "refuses UPDATE, even through update_all and raw SQL" do
    refused(/append-only/) { rows.update_all(status: "not_required") }
    refused(/append-only/) { conn.execute("UPDATE employee_attendance_requirements SET reason = 'x'") }
    expect(row.reload.status).to eq("required")
  end

  it "refuses DELETE, even through delete_all and raw SQL" do
    refused(/append-only/) { rows.delete_all }
    refused(/append-only/) { conn.execute("DELETE FROM employee_attendance_requirements") }
    expect(EmployeeAttendanceRequirement.exists?(row.id)).to be(true)
  end

  it "enforces the status, source, not-reviewed and basis rules in the database" do
    refused(/employee_attendance_requirements_status/) { insert(status: "exempt") }
    refused(/employee_attendance_requirements_source/) { insert(source: "import") }
    refused(/not_reviewed_backfill_only/) { insert(status: "not_reviewed", source: "hr_change") }
    refused(/basis_backfill_only/) { insert(effective_date_basis: "hire_date") }
    expect { insert(status: "not_reviewed", source: "backfill", effective_date_basis: "hire_date") }
      .to change(EmployeeAttendanceRequirement, :count).by(1)
  end

  it "allows two rows for the same employee and date (no unique index; ordered by id)" do
    expect { insert(effective_from: row.effective_from.to_s) }.to change(EmployeeAttendanceRequirement, :count).by(1)
  end

  it "keeps the employee: deleting a user with history is refused by the foreign key" do
    refused(/foreign key/) { conn.execute("DELETE FROM users WHERE id = #{employee.id}") }
  end

  it "makes OrganizationAccess::DeleteUser refuse an employee with history (:linked_records)" do
    owner  = create(:user, business: business).tap { |user| business.update!(owner: user) }
    result = OrganizationAccess::DeleteUser.new(employee.id, actor: owner).call
    expect(result).not_to be_ok
    expect(result.error).to eq(:linked_records)
    expect(User.exists?(employee.id)).to be(true)
  end

  describe "migration rollback guards" do
    it "refuses to drop the history table while it has rows" do
      expect { ActiveRecord::Migration.suppress_messages { CreateEmployeeAttendanceRequirements.new.down } }
        .to raise_error(ActiveRecord::IrreversibleMigration, /never dropped/)
      expect(conn.table_exists?(:employee_attendance_requirements)).to be(true)
    end

    it "refuses to drop employment_ended_on once an end date is recorded" do
      employee.update_column(:employment_ended_on, Date.new(2026, 12, 31))
      expect { ActiveRecord::Migration.suppress_messages { AddEmploymentEndedOnToUsers.new.down } }
        .to raise_error(ActiveRecord::IrreversibleMigration, /recorded end dates/)
      expect(conn.column_exists?(:users, :employment_ended_on)).to be(true)
    end
  end
end
