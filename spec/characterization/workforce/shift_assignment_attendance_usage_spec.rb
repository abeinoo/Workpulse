require "rails_helper"

# Characterization (F2 M1) — the Workforce → Attendance & Payroll attendance reads
# behind "may this shift assignment be hard-deleted?" (module-boundaries.md §13
# cycle F2; next-pilot-selection.md Milestone 2 §3.3 DS-4), recorded from the
# unchanged code before they move behind a Workforce contract
# (docs/architecture/workforce-shift-assignment-attendance-baseline-failures.txt).
#
# Pins: ShiftAssignment#has_attendance_records? / #deletable? (results and query
# counts, including the existing memoization quirk: only `true` is cached), the
# preloaded `has_attendance` attribute, soft-deleted attendance still counting,
# the index's single EXISTS column (exact SQL, one attendance query whatever the
# row count, data-deletable per row), the single destroy
# (refused with attendance) and bulk delete (only deletable rows, one EXISTS
# query per candidate).
RSpec.describe "Characterization: shift assignment attendance usage (F2 M1)", type: :request do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  EXISTS_SQL = "EXISTS(SELECT 1 FROM attendance_records ar WHERE ar.shift_assignment_id = shift_assignments.id LIMIT 1) " \
               "AS has_attendance".freeze

  def future_assignment
    create(:shift_assignment, user: create(:user, business: business), branch: branch,
                              shift: create(:shift, :fixed_time, business: business),
                              effective_from: 1.month.from_now.to_date, effective_to: nil)
  end

  def attend!(assignment, deleted: false)
    AttendanceRecord.create!(
      user: assignment.user, branch: branch, shift_assignment: assignment, work_date: Date.current, date: Date.current,
      check_in_at: Time.zone.parse("#{Date.current} 09:00:00"), check_in_source: "biometric_device",
      late_minutes: 0, early_leave_minutes: 0, status: "incomplete", deleted_at: (deleted ? Time.current : nil)
    )
  end

  def sql_of(&block)
    statements = []
    subscriber = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    statements
  end

  describe "ShiftAssignment#has_attendance_records? / #deletable?" do
    it "false without attendance: one EXISTS query per call (false is not memoized)" do
      assignment = ShiftAssignment.find(future_assignment.id)
      statements = sql_of { 2.times { expect(assignment.has_attendance_records?).to be(false) } }
      expect(statements.size).to eq(2)
      expect(statements).to all(match(/SELECT 1 AS one FROM "attendance_records" WHERE "attendance_records"\."shift_assignment_id" = \$1 LIMIT \$2/))
      expect(assignment.deletable?).to be(true)
    end

    it "true with attendance: one query, then memoized" do
      assignment = future_assignment
      attend!(assignment)
      assignment = ShiftAssignment.find(assignment.id)
      expect(count_queries { 3.times { expect(assignment.has_attendance_records?).to be(true) } }).to eq(1)
      expect(count_queries { expect(assignment.deletable?).to be(false) }).to eq(0)
    end

    it "a soft-deleted attendance record still counts" do
      assignment = future_assignment
      attend!(assignment, deleted: true)
      expect(ShiftAssignment.find(assignment.id).has_attendance_records?).to be(true)
    end

    it "reads a preloaded has_attendance attribute without querying" do
      assignment = future_assignment
      loaded_true  = ShiftAssignment.select("shift_assignments.*", "TRUE AS has_attendance").find(assignment.id)
      loaded_false = ShiftAssignment.select("shift_assignments.*", "FALSE AS has_attendance").find(assignment.id)
      expect(count_queries do
        expect(loaded_true.has_attendance_records?).to be(true)
        expect(loaded_false.deletable?).to be(true)
      end).to eq(0)
    end
  end

  describe "index" do
    before { sign_in owner }

    def index_statements = sql_of { get shift_assignments_path(tab: "upcoming") }

    it "selects one EXISTS column (exact SQL) and never queries attendance per row" do
      with = future_assignment
      future_assignment
      attend!(with)

      statements = index_statements
      expect(response).to have_http_status(:ok)
      attendance = statements.grep(/attendance_records/)
      expect(attendance.size).to eq(1)
      expect(attendance.first).to include(EXISTS_SQL)

      rows = Nokogiri::HTML(response.body).css("[data-deletable]")
      expect(rows.map { _1["data-deletable"] }.sort).to eq(%w[false true])
    end

    it "runs exactly one attendance query for one and for three assignments" do
      attend!(future_assignment)
      expect(index_statements.grep(/attendance_records/).size).to eq(1)
      2.times { attend!(future_assignment) }
      expect(index_statements.grep(/attendance_records/).size).to eq(1)
    end
  end

  describe "destroy" do
    before { sign_in owner }

    it "deletes an assignment without attendance" do
      assignment = future_assignment
      expect { delete shift_assignment_path(assignment) }.to change(ShiftAssignment, :count).by(-1)
      expect(response).to redirect_to(shift_assignments_path(tab: "upcoming"))
    end

    it "refuses one with attendance (policy) and keeps it" do
      assignment = future_assignment
      attend!(assignment)
      expect { delete shift_assignment_path(assignment) }.not_to change(ShiftAssignment, :count)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end
  end

  describe "bulk delete" do
    before { sign_in owner }

    it "deletes only the deletable candidates, one EXISTS query each, and reports their count" do
      used, free_a, free_b = future_assignment, future_assignment, future_assignment
      attend!(used)

      statements = sql_of do
        delete bulk_delete_shift_assignments_path, params: { assignment_ids: [ used.id, free_a.id, free_b.id ] }
      end
      expect(ShiftAssignment.where(id: [ used.id, free_a.id, free_b.id ]).pluck(:id)).to eq([ used.id ])
      expect(statements.grep(/FROM "attendance_records" WHERE "attendance_records"\."shift_assignment_id"/).size).to eq(3)
      expect(response).to redirect_to(shift_assignments_path(tab: "upcoming"))
      expect(flash[:notice]).to eq(I18n.t("flash.assignments_bulk_deleted", count: 2))
    end
  end
end
