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

  # ── Employee availability for new regular assignments ──────────────────────
  # Picker + server-side guard backed by Shifts::AssignmentEligibility.

  describe "employee availability (branch manager)" do
    let(:manager)        { create(:user, :branch_manager, business: business) }
    let(:manager_branch) { Branch.find_by!(branch_manager_id: manager.id) }
    let(:other_branch)   { create(:branch, business: business, name: "Nasr City") }

    def assigned_employee(branch:, ends_on:)
      fresh_employee.tap do |u|
        create(:shift_assignment, user: u, branch: branch, shift: fresh_shift,
                                  effective_from: 1.month.ago.to_date, effective_to: ends_on)
      end
    end

    before { sign_in manager }

    describe "GET /shift_assignments/new" do
      let!(:new_hire)          { fresh_employee }
      let!(:transfer_soon)     { assigned_employee(branch: other_branch,   ends_on: Date.current + 3) }
      let!(:transfer_later)    { assigned_employee(branch: other_branch,   ends_on: Date.current + 20) }
      let!(:own_soon)          { assigned_employee(branch: manager_branch, ends_on: Date.current + 3) }
      let!(:own_later)         { assigned_employee(branch: manager_branch, ends_on: Date.current + 20) }
      let!(:own_open_ended)    { assigned_employee(branch: manager_branch, ends_on: nil) }
      let!(:other_open_ended)  { assigned_employee(branch: other_branch,   ends_on: nil) }
      let!(:ends_today)        { assigned_employee(branch: other_branch,   ends_on: Date.current) }
      let!(:remote)            { create(:user, business: business, requires_shift_assignment: false) }
      let!(:business_owner)    { create(:user, :owner, business: business) }

      let(:page) { Nokogiri::HTML(response.body) }

      def regular_group(label)
        page.css("select#shift_assignment_user_id optgroup[label='#{label}'] option")
      end

      def regular_ids
        page.css("select#shift_assignment_user_id option").map { |o| o["value"] }.reject(&:blank?).map(&:to_i)
      end

      before { get new_shift_assignment_path }

      it "lists only eligible employees in the regular picker" do
        expect(regular_ids).to include(new_hire.id, transfer_soon.id, own_soon.id, ends_today.id)
        expect(regular_ids).not_to include(transfer_later.id, own_later.id,
                                           own_open_ended.id, other_open_ended.id)
      end

      it "never lists employees who don't work shifts, or the owner" do
        expect(regular_ids).not_to include(remote.id, business_owner.id)
      end

      it "groups employees without an active assignment under Available now" do
        expect(regular_group("Available now").map { |o| o["value"].to_i }).to include(new_hire.id)
      end

      it "shows the current branch and end date for another branch's employee ending soon" do
        option = regular_group("Available soon").find { |o| o["value"].to_i == transfer_soon.id }
        expect(option).to be_present
        expect(option.text).to include("Nasr City")
        expect(option.text).to include(I18n.l(Date.current + 3))
      end

      it "keeps the manager's scoped list for temporary coverage (disabled until selected)" do
        coverage = page.css("select#shift_assignment_user_id_coverage")
        expect(coverage.attr("disabled")).to be_present
        ids = coverage.css("option").map { |o| o["value"] }.reject(&:blank?).map(&:to_i)
        expect(ids).to include(own_open_ended.id)
        expect(ids).not_to include(other_open_ended.id)
      end
    end

    describe "POST /shift_assignments" do
      def post_regular(user, effective_from: Date.current)
        post shift_assignments_path, params: {
          shift_assignment: {
            user_id: user.id, shift_id: fresh_shift.id, branch_id: manager_branch.id,
            effective_from: effective_from.to_s, assignment_kind: "regular"
          }
        }
      end

      it "rejects an employee whose assignment at another branch is open-ended" do
        emp = assigned_employee(branch: other_branch, ends_on: nil)
        expect { post_regular(emp) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("not available for a new assignment")
        expect(response.body).to include("within 7 days")
      end

      it "rejects an employee whose assignment runs beyond the availability window" do
        emp = assigned_employee(branch: other_branch, ends_on: Date.current + 20)
        expect { post_regular(emp, effective_from: Date.current + 21) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects an own-branch employee with an ongoing assignment" do
        emp = assigned_employee(branch: manager_branch, ends_on: nil)
        expect { post_regular(emp, effective_from: 1.month.from_now.to_date) }.not_to change(ShiftAssignment, :count)
      end

      it "accepts another branch's employee whose assignment ends within the window" do
        emp = assigned_employee(branch: other_branch, ends_on: Date.current + 3)
        expect { post_regular(emp, effective_from: Date.current + 4) }.to change(ShiftAssignment, :count).by(1)
        expect(response).to redirect_to(shift_assignments_path)
      end

      it "rejects an employee who doesn't work shifts, despite having no assignment" do
        emp = create(:user, business: business, requires_shift_assignment: false)
        expect { post_regular(emp) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects the business owner" do
        business_owner = create(:user, :owner, business: business)
        expect { post_regular(business_owner) }.not_to change(ShiftAssignment, :count)
      end

      it "accepts a newly hired employee with no assignment" do
        expect { post_regular(fresh_employee) }.to change(ShiftAssignment, :count).by(1)
      end

      it "still applies the existing overlap rules to eligible employees" do
        emp = assigned_employee(branch: manager_branch, ends_on: Date.current + 3)
        expect { post_regular(emp, effective_from: Date.current) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "exempts temporary coverage from the regular availability rule" do
        emp = assigned_employee(branch: manager_branch, ends_on: nil)
        expect {
          post shift_assignments_path, params: {
            shift_assignment: {
              user_id: emp.id, shift_id: fresh_shift.id, branch_id: other_branch.id,
              effective_from: Date.current.to_s, effective_to: (Date.current + 2).to_s,
              assignment_kind: "temporary_coverage", reason: "Covering absence"
            }
          }
        }.to change(ShiftAssignment, :count).by(1)
      end
    end
  end

  # ── Temporary coverage target branch ───────────────────────────────────────
  # A coverage assignment's own branch_id is the target branch; the employee's
  # home branch stays on their regular assignment.

  describe "temporary coverage target branch (branch manager)" do
    let(:manager)        { create(:user, :branch_manager, business: business) }
    let(:manager_branch) { Branch.find_by!(branch_manager_id: manager.id).tap { |b| b.update!(name: "Nasr City") } }
    let!(:shubra)        { create(:branch, business: business, name: "Shubra") }
    let!(:closed_branch) { create(:branch, business: business, name: "Closed", active: false) }
    let(:foreign_branch) { create(:branch, business: create(:business)) }
    let(:shift)          { fresh_shift }

    let!(:employee) do
      fresh_employee.tap do |u|
        create(:shift_assignment, user: u, branch: manager_branch, shift: shift,
                                  effective_from: 1.month.ago.to_date, effective_to: nil)
      end
    end
    let!(:regular_assignment) { employee.shift_assignments.sole }

    let(:coverage_from) { Date.current + 1 }
    let(:coverage_to)   { Date.current + 5 }

    def post_coverage(branch_id:, effective_to: coverage_to, shift_id: shift.id, user: employee)
      post shift_assignments_path, params: {
        shift_assignment: {
          user_id: user.id, shift_id: shift_id, branch_id: branch_id,
          effective_from: coverage_from.to_s, effective_to: effective_to&.to_s,
          assignment_kind: "temporary_coverage", reason: "Covering another employee"
        }
      }
    end

    before { sign_in manager }

    describe "GET /shift_assignments/new" do
      before { get new_shift_assignment_path }

      let(:page) { Nokogiri::HTML(response.body) }

      def option_names(css)
        page.css("#{css} option").map(&:text).reject { |t| t.end_with?("—") }
      end

      it "offers other active branches as coverage targets, never the manager's own" do
        expect(option_names("select#shift_assignment_branch_id_coverage")).to eq([ "Shubra" ])
      end

      it "keeps the regular branch field on the manager's branches" do
        expect(option_names("select#shift_assignment_branch_id")).to eq([ "Nasr City" ])
      end

      it "renders the coverage branch disabled (not submitted) for a regular assignment" do
        expect(page.css("select#shift_assignment_branch_id_coverage").attr("disabled")).to be_present
        expect(page.css("select#shift_assignment_branch_id").attr("disabled")).to be_nil
      end

      it "labels coverage employees with their current branch" do
        option = page.css("select#shift_assignment_user_id_coverage option[value='#{employee.id}']").first
        expect(option.text).to include("Current branch: Nasr City")
        expect(option["data-current-branch"]).to eq("Nasr City")
      end
    end

    describe "POST /shift_assignments" do
      it "creates the coverage at the target branch" do
        expect { post_coverage(branch_id: shubra.id) }.to change(ShiftAssignment, :count).by(1)

        coverage = ShiftAssignment.order(:id).last
        expect(coverage).to be_temporary_coverage
        expect(coverage.branch).to eq(shubra)
        expect([ coverage.effective_from, coverage.effective_to ]).to eq([ coverage_from, coverage_to ])
      end

      it "leaves the employee's permanent branch untouched" do
        post_coverage(branch_id: shubra.id)

        expect(regular_assignment.reload).to have_attributes(branch_id: manager_branch.id, effective_to: nil)
        expect(Shifts::AssignmentResolver.for(user: employee, date: coverage_from).branch).to eq(shubra)
        expect(Shifts::AssignmentResolver.for(user: employee, date: coverage_to + 1).branch).to eq(manager_branch)
      end

      it "requires a target branch" do
        expect { post_coverage(branch_id: "") }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects the manager's own branch as the target" do
        expect { post_coverage(branch_id: manager_branch.id) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Choose a coverage branch other than your own branch.")
      end

      it "rejects a branch from another business" do
        expect { post_coverage(branch_id: foreign_branch.id) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects an inactive branch" do
        expect { post_coverage(branch_id: closed_branch.id) }.not_to change(ShiftAssignment, :count)
      end

      it "still requires an end date" do
        expect { post_coverage(branch_id: shubra.id, effective_to: nil) }.not_to change(ShiftAssignment, :count)
      end

      it "still rejects an end date before the start date" do
        expect { post_coverage(branch_id: shubra.id, effective_to: coverage_from - 1) }
          .not_to change(ShiftAssignment, :count)
      end

      it "still rejects clock-overlapping coverage at two branches" do
        post_coverage(branch_id: shubra.id)
        elsewhere = create(:branch, business: business)
        expect { post_coverage(branch_id: elsewhere.id) }.not_to change(ShiftAssignment, :count)
        expect(response.body).to include("already has an overlapping shift")
      end

      it "still rejects overlapping coverage at the same branch" do
        post_coverage(branch_id: shubra.id)
        hour_based = create(:shift, :hour_based, business: business)
        expect { post_coverage(branch_id: shubra.id, shift_id: hour_based.id) }.not_to change(ShiftAssignment, :count)
        expect(response.body).to include("overlapping assignment at this branch")
      end

      it "creates a regular assignment at its branch with no coverage branch involved" do
        new_hire = fresh_employee
        post shift_assignments_path, params: {
          shift_assignment: {
            user_id: new_hire.id, shift_id: shift.id, branch_id: manager_branch.id,
            effective_from: Date.current.to_s, assignment_kind: "regular"
          }
        }
        expect(new_hire.shift_assignments.sole).to have_attributes(branch_id: manager_branch.id,
                                                                   assignment_kind: "regular")
      end
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
