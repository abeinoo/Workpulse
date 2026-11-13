require "rails_helper"

# R3.2 G2: the Workforce read API of the attendance requirement history —
# derived on read (OD-4), same-date rows by id (OD-15 T3), "today" = the
# business day — and the per-employee advisory lock (L3, OD-3).
RSpec.describe Employee::AttendanceRequirements do
  let(:business) { create(:business, timezone: "Africa/Cairo", business_day_start_hour: 6) }
  let(:employee) { create(:user, business: business) }
  let(:other)    { create(:user, business: business) }

  def row(user = employee, from:, status: "required", source: "creation")
    create(:employee_attendance_requirement, user: user, status: status, source: source,
                                             reason: (source == "hr_change" ? "change" : nil),
                                             effective_from: from,
                                             effective_date_basis: (source == "backfill" ? "hire_date" : nil))
  end

  describe ".status_on" do
    it "is :not_reviewed with no row, and before the first row — never :not_required" do
      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 5, 1))).to eq(:not_reviewed)
      row(from: Date.new(2026, 3, 1), status: "not_required")
      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 2, 28))).to eq(:not_reviewed)
    end

    it "returns the latest row on or before the date, including future-dated rows once they take effect" do
      row(from: Date.new(2026, 1, 1))
      row(from: Date.new(2026, 6, 1), status: "not_required", source: "hr_change")

      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 5, 31))).to eq(:required)
      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 6, 1))).to eq(:not_required)
    end

    it "lets the later row of one date win (ordered by id)" do
      row(from: Date.new(2026, 1, 1))
      row(from: Date.new(2026, 1, 1), status: "not_required", source: "hr_change")
      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 1, 1))).to eq(:not_required)
    end

    it "reports an explicit not-reviewed backfill row as :not_reviewed" do
      row(from: Date.new(2025, 1, 1), status: "not_reviewed", source: "backfill")
      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 1, 1))).to eq(:not_reviewed)
    end

    it "never reads another employee's rows" do
      row(other, from: Date.new(2026, 1, 1), status: "not_required", source: "hr_change")
      expect(described_class.status_on(user_id: employee.id, date: Date.new(2026, 2, 1))).to eq(:not_reviewed)
    end
  end

  describe ".timeline" do
    it "lists the employee's rows oldest first, same-date rows by id" do
      b = row(from: Date.new(2026, 3, 1))
      a = row(from: Date.new(2026, 1, 1))
      c = row(from: Date.new(2026, 3, 1), status: "not_required", source: "hr_change")
      expect(described_class.timeline(user_id: employee.id)).to eq([ a, b, c ])
    end
  end

  describe ".today and .in_force_scope (business day)" do
    before do
      row(from: Date.new(2026, 1, 1))
      row(from: Date.new(2026, 12, 1), status: "not_required", source: "hr_change")
      row(other, from: Date.new(2026, 1, 1), status: "not_required", source: "hr_change")
    end

    it "is still the previous business day before 06:00 Cairo" do
      travel_to(Time.find_zone("Africa/Cairo").local(2026, 12, 1, 5, 59)) do
        expect(described_class.today(business)).to eq(Date.new(2026, 11, 30))
        expect(described_class.in_force_scope(business: business).find_by(user_id: employee.id)).to be_required
      end
    end

    it "rolls over at 06:00 Cairo, not at midnight or UTC" do
      travel_to(Time.find_zone("Africa/Cairo").local(2026, 12, 1, 6, 0)) do
        expect(described_class.today(business)).to eq(Date.new(2026, 12, 1))
        expect(described_class.in_force_scope(business: business).find_by(user_id: employee.id)).to be_not_required
      end
    end

    it "agrees with status_on for every employee and excludes other businesses" do
      stranger = create(:user, business: create(:business))
      row(stranger, from: Date.new(2026, 1, 1))
      date  = Date.new(2026, 6, 15)
      scope = described_class.in_force_scope(business: business, date: date)

      expect(scope.map(&:user_id)).to contain_exactly(employee.id, other.id)
      scope.each do |in_force|
        expect(in_force.status.to_sym).to eq(described_class.status_on(user_id: in_force.user_id, date: date))
      end
    end
  end

  describe ".lock_employee!" do
    def advisory_locks
      ActiveRecord::Base.connection.select_rows(<<~SQL).map { |classid, objid| [ classid.to_i, objid.to_i ] }
        SELECT classid, objid FROM pg_locks
        WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
      SQL
    end

    it "takes a transaction-scoped advisory lock keyed by the employee, not a users row lock" do
      ActiveRecord::Base.transaction(requires_new: true) do
        described_class.lock_employee!(user_id: employee.id)
        expect(advisory_locks).to include([ described_class::LOCK_NAMESPACE, employee.id ])
        expect(advisory_locks).not_to include([ described_class::LOCK_NAMESPACE, other.id ])
      end
    end

    it "refuses to run outside a transaction" do
      allow(EmployeeAttendanceRequirement.connection).to receive(:transaction_open?).and_return(false)
      expect { described_class.lock_employee!(user_id: employee.id) }
        .to raise_error(described_class::LockOutsideTransaction)
    end

    it "uses a namespace no other advisory lock in app/ uses" do
      sources = Dir[Rails.root.join("app/**/*.rb")].reject { |path| path.end_with?("employee/attendance_requirements.rb") }
                                                   .map { |path| File.read(path) }.join("\n")
      expect(sources).not_to match(/0x4541\b|\b#{described_class::LOCK_NAMESPACE}\b/)
    end
  end
end
