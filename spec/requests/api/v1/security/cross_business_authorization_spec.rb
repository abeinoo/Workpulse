require "rails_helper"

# Regression coverage for the cross-business / cross-scope authorization fixes
# S1 and S2 (docs/api/baseline.md). The business is always derived from the
# authenticated user; business_id / branch_id / user_id in params are never
# trusted to widen access.
RSpec.describe "API v1 security — cross-business authorization", type: :request do
  let(:business_a) { create(:business) }
  let(:business_b) { create(:business) }

  # ── S1: POST /api/v1/shift_assignments ───────────────────────────────────────
  describe "S1 — POST /api/v1/shift_assignments" do
    let(:branch_a)   { create(:branch, business: business_a) }
    let(:shift_a)    { create(:shift, :fixed_time, business: business_a) }
    let(:branch_b)   { create(:branch, business: business_b) }
    let(:shift_b)    { create(:shift, :fixed_time, business: business_b) }

    let(:manager_a)  { api_user_with(business_a, :view_shifts, :assign_shifts) }
    let(:manager_b)  { api_user_with(business_b, :view_shifts, :assign_shifts) }
    let(:employee_a) { create(:user, business: business_a) }
    let(:employee_b) { create(:user, business: business_b) }

    def assign(user:, shift:, branch:, extra: {})
      post "/api/v1/shift_assignments",
           params: { shift_assignment: { user_id: user.id, shift_id: shift.id, branch_id: branch.id,
                                         effective_from: Date.current }.merge(extra) },
           as: :json
    end

    it "1. allows a Business A manager to assign a Business A employee" do
      sign_in manager_a
      expect { assign(user: employee_a, shift: shift_a, branch: branch_a) }
        .to change { ShiftAssignment.where(user: employee_a).count }.by(1)
      expect_legacy_success(:created)
      expect(api_data).to include("user_id" => employee_a.id, "shift_id" => shift_a.id, "branch_id" => branch_a.id)
    end

    it "2. rejects a Business A manager assigning a Business B employee" do
      sign_in manager_a
      expect { assign(user: employee_b, shift: shift_a, branch: branch_a) }
        .not_to change(ShiftAssignment, :count)
      expect_legacy_error(:unprocessable_content, message: "Employee not found in this business")
    end

    it "3. rejects a Business B manager assigning a Business A employee" do
      sign_in manager_b
      expect { assign(user: employee_a, shift: shift_b, branch: branch_b) }
        .not_to change(ShiftAssignment, :count)
      expect_legacy_error(:unprocessable_content, message: "Employee not found in this business")
    end

    describe "4. business_id manipulation" do
      before { sign_in manager_a }

      it "ignores business_id inside shift_assignment params" do
        expect { assign(user: employee_b, shift: shift_a, branch: branch_a, extra: { business_id: business_b.id }) }
          .not_to change(ShiftAssignment, :count)
        expect_legacy_error(:unprocessable_content, message: "Employee not found in this business")
      end

      it "ignores a top-level business_id" do
        expect {
          post "/api/v1/shift_assignments",
               params: { business_id: business_b.id,
                         shift_assignment: { user_id: employee_b.id, shift_id: shift_a.id, branch_id: branch_a.id,
                                             effective_from: Date.current } },
               as: :json
        }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "cannot switch to Business B by sending all of Business B's ids" do
        expect { assign(user: employee_b, shift: shift_b, branch: branch_b, extra: { business_id: business_b.id }) }
          .not_to change(ShiftAssignment, :count)
        expect_legacy_error(:unprocessable_content)
      end

      it "gives the same answer for a foreign user and a non-existent user (no existence oracle)" do
        post "/api/v1/shift_assignments",
             params: { shift_assignment: { user_id: 0, shift_id: shift_a.id, branch_id: branch_a.id,
                                           effective_from: Date.current } },
             as: :json
        expect_legacy_error(:unprocessable_content, message: "Employee not found in this business")
      end
    end

    describe "5. unauthorized users cannot cross business boundaries" do
      it "returns 403 for a user without assign_shifts and creates nothing" do
        sign_in employee_a
        expect { assign(user: employee_b, shift: shift_a, branch: branch_a) }
          .not_to change(ShiftAssignment, :count)
        expect_legacy_error(:forbidden)
      end

      it "returns 401 for an unauthenticated request and creates nothing" do
        expect { assign(user: employee_b, shift: shift_a, branch: branch_a) }
          .not_to change(ShiftAssignment, :count)
        expect_devise_unauthenticated
      end

      it "cannot modify or delete another business's assignment (404)" do
        foreign = create(:shift_assignment, user: employee_b, shift: shift_b, branch: branch_b)
        sign_in manager_a

        patch "/api/v1/shift_assignments/#{foreign.id}",
              params: { shift_assignment: { effective_to: Date.current + 30 } }, as: :json
        expect_legacy_error(:not_found)

        delete "/api/v1/shift_assignments/#{foreign.id}", as: :json
        expect_legacy_error(:not_found)
        expect(foreign.reload.effective_to).to be_nil
      end
    end
  end

  # ── S2: GET /api/v1/reports/attendance ───────────────────────────────────────
  describe "S2 — GET /api/v1/reports/attendance" do
    let(:work_date) { Date.new(2026, 9, 10) }
    let(:range)     { { start_date: "2026-09-01", end_date: "2026-09-30" } }

    let(:own_branch)    { create(:branch, business: business_a) }
    let(:other_branch)  { create(:branch, business: business_a) }
    let(:foreign_branch) { create(:branch, business: business_b) }

    let(:own_employee)     { create(:user, business: business_a) }
    let(:other_employee)   { create(:user, business: business_a) }
    let(:foreign_employee) { create(:user, business: business_b) }

    let(:manager) { api_user_with(business_a, :view_employees, :view_attendance) }

    before do
      own_branch.update_column(:branch_manager_id, manager.id)
      [ [ own_employee, own_branch, business_a ], [ other_employee, other_branch, business_a ],
        [ foreign_employee, foreign_branch, business_b ] ].each do |user, branch, business|
        create(:attendance_record, :checked_out, business: business, user: user, branch: branch,
               date: work_date, work_date: work_date)
      end
    end

    def report(user, extra = {})
      sign_in user
      get "/api/v1/reports/attendance", params: range.merge(extra), as: :json
    end

    def reported_user_ids = api_data["employees"].map { |row| row["user_id"] }

    describe "1. a branch manager can access their own branch" do
      it "with branch_id" do
        report(manager, branch_id: own_branch.id)
        expect_legacy_success
        expect(api_data["branch_id"]).to eq(own_branch.id)
        expect(reported_user_ids).to eq([ own_employee.id ])
      end

      it "without branch_id — limited to the branches they manage" do
        report(manager)
        expect_legacy_success
        expect(reported_user_ids).to eq([ own_employee.id ])
        expect(api_data.dig("totals", "total_days")).to eq(1)
      end
    end

    it "2. a branch manager cannot access another branch of the same business (404)" do
      report(manager, branch_id: other_branch.id)
      expect_legacy_error(:not_found)
    end

    it "3. a branch manager cannot access another business's branch (404)" do
      report(manager, branch_id: foreign_branch.id)
      expect_legacy_error(:not_found)
    end

    it "4. business_id in params cannot switch or widen the business" do
      report(manager, business_id: business_b.id)
      expect_legacy_success
      expect(reported_user_ids).to eq([ own_employee.id ])
    end

    describe "5. branch_id manipulation" do
      it "cannot reach a non-existent branch" do
        report(manager, branch_id: 0)
        expect_legacy_error(:not_found)
      end

      it "cannot request several branches at once" do
        report(manager, branch_id: [ own_branch.id, other_branch.id ])
        expect_legacy_error(:not_found)
      end

      it "cannot combine business_id and branch_id to reach another business" do
        report(manager, business_id: business_b.id, branch_id: foreign_branch.id)
        expect_legacy_error(:not_found)
      end
    end

    describe "6. authorized higher-level users keep their access" do
      it "the owner sees the whole business, never another business" do
        owner = create(:user, :owner, business: business_a)
        report(owner)
        expect(reported_user_ids).to contain_exactly(own_employee.id, other_employee.id)
      end

      it "the owner may select any branch of the business" do
        owner = create(:user, :owner, business: business_a)
        report(owner, branch_id: other_branch.id)
        expect_legacy_success
        expect(reported_user_ids).to eq([ other_employee.id ])
      end

      it "a user with a configured business scope sees the whole business" do
        hr = api_user_with(business_a, :view_employees, :view_attendance, scopes: { "view_attendance" => "business" })
        report(hr)
        expect(reported_user_ids).to contain_exactly(own_employee.id, other_employee.id)

        report(hr, branch_id: other_branch.id)
        expect(reported_user_ids).to eq([ other_employee.id ])
      end

      it "an area manager sees every branch in their area" do
        area_manager = api_user_with(business_a, :view_employees, :view_attendance)
        own_branch.update_column(:area_manager_id, area_manager.id)
        other_branch.update_column(:area_manager_id, area_manager.id)
        report(area_manager)
        expect(reported_user_ids).to contain_exactly(own_employee.id, other_employee.id)
      end
    end

    it "a view_employees holder who manages no branch gets an empty report, not the business" do
      staff = api_user_with(business_a, :view_employees)
      report(staff)
      expect_legacy_success
      expect(reported_user_ids).to be_empty
    end

    it "still requires view_employees or manage_employees (401, unchanged)" do
      report(own_employee)
      expect_legacy_error(:unauthorized, message: "Not authorized")
    end
  end
end
