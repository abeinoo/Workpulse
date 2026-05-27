require "rails_helper"

RSpec.describe "ShiftAssignments", type: :request do
  # ── Helpers ──────────────────────────────────────────────────────────────────

  let(:business)  { create(:business, timezone: "UTC") }
  let(:branch)    { create(:branch, business: business) }
  let(:owner)     { create(:user, :super_admin, business: business) }

  # Always use a fresh user per helper call to avoid the overlap validation
  # (each ShiftAssignment factory needs a distinct user when using the same shift/branch).
  def fresh_employee
    create(:user, business: business)
  end

  def fresh_shift
    create(:shift, :fixed_time, business: business)
  end

  def make_future_assignment(user: nil, shift: nil)
    create(:shift_assignment,
           user:           user || fresh_employee,
           branch:         branch,
           shift:          shift || fresh_shift,
           effective_from: 1.month.from_now.to_date,
           effective_to:   nil)
  end

  def make_active_assignment(user: nil, shift: nil)
    create(:shift_assignment,
           user:           user || fresh_employee,
           branch:         branch,
           shift:          shift || fresh_shift,
           effective_from: 1.month.ago.to_date,
           effective_to:   nil)
  end

  def make_expired_assignment(user: nil, shift: nil)
    create(:shift_assignment,
           user:           user || fresh_employee,
           branch:         branch,
           shift:          shift || fresh_shift,
           effective_from: 3.months.ago.to_date,
           effective_to:   1.week.ago.to_date)
  end

  def attach_attendance_record(assignment)
    AttendanceRecord.create!(
      user:                assignment.user,
      branch:              assignment.branch,
      shift_assignment:    assignment,
      work_date:           1.week.ago.to_date,
      date:                1.week.ago.to_date,
      check_in_at:         1.week.ago.change(hour: 9),
      check_in_source:     "biometric_device",
      late_minutes:        0,
      early_leave_minutes: 0,
      status:              "incomplete"
    )
  end

  # ── GET /shift_assignments (index) ─────────────────────────────────────────

  describe "GET /shift_assignments" do
    before do
      sign_in owner
      make_active_assignment
    end

    it "returns 200 for authenticated owner" do
      get shift_assignments_path
      expect(response).to have_http_status(:ok)
    end

    context "tab parameter" do
      before do
        make_future_assignment
        make_expired_assignment
      end

      %w[active upcoming expired all].each do |tab|
        it "accepts tab=#{tab}" do
          get shift_assignments_path(tab: tab)
          expect(response).to have_http_status(:ok)
        end
      end

      it "ignores unknown tab values (falls back to active)" do
        get shift_assignments_path(tab: "nonsense")
        expect(response).to have_http_status(:ok)
      end
    end

    context "filter parameters" do
      let(:emp) { fresh_employee }

      it "accepts q (employee search)" do
        get shift_assignments_path(q: emp.first_name, tab: "all")
        expect(response).to have_http_status(:ok)
      end

      it "accepts branch_id filter" do
        get shift_assignments_path(branch_id: branch.id, tab: "all")
        expect(response).to have_http_status(:ok)
      end

      it "accepts shift_type filter" do
        get shift_assignments_path(shift_type: "fixed_time", tab: "all")
        expect(response).to have_http_status(:ok)
      end

      it "accepts from/to date filters" do
        get shift_assignments_path(from: 1.year.ago.to_date.to_s,
                                   to:   Date.current.to_s, tab: "all")
        expect(response).to have_http_status(:ok)
      end
    end

    it "redirects unauthenticated requests to login" do
      sign_out owner
      get shift_assignments_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # ── POST /shift_assignments (create) sets created_by ───────────────────────

  describe "POST /shift_assignments" do
    before { sign_in owner }

    let(:emp)   { fresh_employee }
    let(:shift) { fresh_shift }

    it "records the current user as created_by" do
      post shift_assignments_path, params: {
        shift_assignment: {
          user_id:        emp.id,
          shift_id:       shift.id,
          branch_id:      branch.id,
          effective_from: 2.months.from_now.to_date.to_s
        }
      }
      assignment = ShiftAssignment.order(:id).last
      expect(assignment.created_by_id).to eq(owner.id)
    end
  end

  # ── PATCH /shift_assignments/:id/end sets ended_by ─────────────────────────

  describe "PATCH /shift_assignments/:id/end" do
    before { sign_in owner }

    let!(:active) { make_active_assignment }

    it "records the current user as ended_by" do
      patch end_shift_assignment_path(active), params: {
        shift_assignment: { ended_on: Date.current.to_s }
      }
      expect(active.reload.ended_by_id).to eq(owner.id)
    end

    it "redirects to index after a successful end" do
      patch end_shift_assignment_path(active), params: {
        shift_assignment: { ended_on: Date.current.to_s }
      }
      expect(response).to redirect_to(shift_assignments_path)
    end
  end

  # ── GET /shift_assignments/:id/confirm_delete ───────────────────────────────

  describe "GET /shift_assignments/:id/confirm_delete" do
    before { sign_in owner }

    context "when assignment is deletable (no attendance records)" do
      let!(:future_a) { make_future_assignment }

      it "renders 200" do
        get confirm_delete_shift_assignment_path(future_a)
        expect(response).to have_http_status(:ok)
      end
    end

    context "when assignment is not deletable (has attendance records)" do
      let!(:active) { make_active_assignment }
      before { attach_attendance_record(active) }

      it "redirects (Pundit rescued → redirect_to root)" do
        get confirm_delete_shift_assignment_path(active)
        expect(response).to redirect_to(root_path)
      end
    end

    it "redirects unauthenticated requests" do
      sign_out owner
      future_a = make_future_assignment
      get confirm_delete_shift_assignment_path(future_a)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # ── DELETE /shift_assignments/:id (destroy) ─────────────────────────────────

  describe "DELETE /shift_assignments/:id" do
    before { sign_in owner }

    context "future assignment with no attendance records" do
      let!(:future_a) { make_future_assignment }

      it "deletes the record" do
        expect {
          delete shift_assignment_path(future_a)
        }.to change(ShiftAssignment, :count).by(-1)
      end

      it "redirects to the upcoming tab" do
        delete shift_assignment_path(future_a)
        expect(response).to redirect_to(shift_assignments_path(tab: "upcoming"))
      end
    end

    context "assignment with attendance records (not deletable)" do
      let!(:active) { make_active_assignment }
      before { attach_attendance_record(active) }

      it "redirects (Pundit rescued — record not deleted)" do
        delete shift_assignment_path(active)
        expect(response).to redirect_to(root_path)
        expect(ShiftAssignment.find_by(id: active.id)).to be_present
      end
    end

    context "as a regular employee" do
      let(:employee) { fresh_employee }
      let!(:future_a) { make_future_assignment(user: employee) }

      before { sign_in employee }

      it "redirects (Pundit rescued — record not deleted)" do
        delete shift_assignment_path(future_a)
        expect(response).to redirect_to(root_path)
        expect(ShiftAssignment.find_by(id: future_a.id)).to be_present
      end
    end
  end

  # ── PATCH /shift_assignments/bulk_end ──────────────────────────────────────

  describe "PATCH /shift_assignments/bulk_end" do
    before { sign_in owner }

    let!(:a1) { make_active_assignment }
    let!(:a2) { make_active_assignment }

    it "ends all selected active assignments" do
      patch bulk_end_shift_assignments_path, params: {
        assignment_ids:   [a1.id, a2.id],
        shift_assignment: { ended_on: Date.current.to_s }
      }
      expect(a1.reload.effective_to).to eq(Date.current)
      expect(a2.reload.effective_to).to eq(Date.current)
    end

    it "records ended_by for each updated assignment" do
      patch bulk_end_shift_assignments_path, params: {
        assignment_ids:   [a1.id],
        shift_assignment: { ended_on: Date.current.to_s }
      }
      expect(a1.reload.ended_by_id).to eq(owner.id)
    end

    it "skips future assignments in the bulk-end selection" do
      future_a = make_future_assignment
      patch bulk_end_shift_assignments_path, params: {
        assignment_ids:   [future_a.id],
        shift_assignment: { ended_on: Date.current.to_s }
      }
      expect(future_a.reload.effective_to).to be_nil
    end

    it "redirects to the active tab" do
      patch bulk_end_shift_assignments_path, params: {
        assignment_ids:   [a1.id],
        shift_assignment: { ended_on: Date.current.to_s }
      }
      expect(response).to redirect_to(shift_assignments_path(tab: "active"))
    end

    it "redirects with alert when no end date is given" do
      patch bulk_end_shift_assignments_path, params: {
        assignment_ids: [a1.id]
        # no shift_assignment[ended_on]
      }
      expect(response).to redirect_to(shift_assignments_path)
    end

    context "as a regular employee" do
      let(:employee) { fresh_employee }
      before { sign_in employee }

      it "redirects (Pundit rescued)" do
        patch bulk_end_shift_assignments_path, params: {
          assignment_ids:   [a1.id],
          shift_assignment: { ended_on: Date.current.to_s }
        }
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ── DELETE /shift_assignments/bulk_delete ──────────────────────────────────

  describe "DELETE /shift_assignments/bulk_delete" do
    before { sign_in owner }

    let!(:f1) { make_future_assignment }
    let!(:f2) { make_future_assignment }

    it "deletes all deletable (future, no records) assignments in the selection" do
      expect {
        delete bulk_delete_shift_assignments_path, params: {
          assignment_ids: [f1.id, f2.id]
        }
      }.to change(ShiftAssignment, :count).by(-2)
    end

    it "skips non-deletable assignments (those with attendance records)" do
      active = make_active_assignment
      attach_attendance_record(active)

      expect {
        delete bulk_delete_shift_assignments_path, params: {
          assignment_ids: [active.id, f1.id]
        }
      }.to change(ShiftAssignment, :count).by(-1)  # only f1 deleted

      expect(ShiftAssignment.find_by(id: active.id)).to be_present
    end

    it "redirects to the upcoming tab" do
      delete bulk_delete_shift_assignments_path, params: {
        assignment_ids: [f1.id]
      }
      expect(response).to redirect_to(shift_assignments_path(tab: "upcoming"))
    end

    context "as a regular employee" do
      let(:employee) { fresh_employee }
      before { sign_in employee }

      it "redirects (Pundit rescued)" do
        delete bulk_delete_shift_assignments_path, params: {
          assignment_ids: [f1.id]
        }
        expect(response).to redirect_to(root_path)
      end
    end
  end
end
