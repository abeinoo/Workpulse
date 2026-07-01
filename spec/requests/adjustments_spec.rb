require "rails_helper"

# End-to-end coverage of the standalone adjustment request workflow:
# create (always Pending, creator != approver), approval by a different user,
# and the payroll lock on processed periods.
RSpec.describe "Adjustments workflow", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  # Branch manager: may create adjustment requests (manage_adjustments) and also
  # holds approve_adjustments — but must never approve their OWN request.
  let(:manager)  { create(:user, :branch_manager, business: business) }
  # Accountant: a different user who can approve.
  let(:approver) { create(:user, :accountant, business: business) }
  let(:shift) { create(:shift, :fixed_time, business: business) }
  let(:employee) do
    u = create(:user, business: business)
    create(:shift_assignment, user: u, branch: branch, shift: shift)
    u
  end

  let!(:draft_period) do
    create(:payroll_period, business: business, status: "draft",
           period_month: 7, period_year: 2026)
  end

  def create_params(overrides = {})
    {
      payroll_adjustment: {
        user_id:         employee.id,
        adjustment_type: "cash_incentive",
        amount:          "500",
        reason:          "Performance bonus",
        period_key:      "2026-7"
      }.merge(overrides)
    }
  end

  # Matches an <option …> tag carrying both value="X" and a selected attribute,
  # regardless of attribute order in the rendered HTML.
  def option_selected?(body, value)
    body =~ /<option(?=[^>]*\bselected\b)(?=[^>]*value="#{Regexp.escape(value)}")[^>]*>/
  end

  describe "GET /adjustments/new (quick-action type preselect)" do
    before { sign_in manager }

    {
      "penalty"          => "penalty",
      "manual_deduction" => "manual_deduction",
      "commission"       => "commission",
      "cash_incentive"   => "cash_incentive"
    }.each do |param, expected|
      it "preselects #{expected} when ?adjustment_type=#{param}" do
        get new_adjustment_path(adjustment_type: param)
        expect(response).to have_http_status(:ok)
        expect(option_selected?(response.body, expected)).to be_truthy
      end
    end

    it "normalises the 'deduction' alias to manual_deduction" do
      get new_adjustment_path(adjustment_type: "deduction")
      expect(option_selected?(response.body, "manual_deduction")).to be_truthy
    end

    it "falls back to the cash_incentive default when no type is supplied" do
      get new_adjustment_path
      expect(option_selected?(response.body, "cash_incentive")).to be_truthy
    end

    it "falls back to the default for an unknown type" do
      get new_adjustment_path(adjustment_type: "bogus")
      expect(option_selected?(response.body, "cash_incentive")).to be_truthy
      expect(option_selected?(response.body, "bogus")).to be_falsey
    end
  end

  describe "GET /adjustments/new (employee picker scope)" do
    it "shows ALL business employees for a business-wide adjustments manager" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_payroll manage_adjustments],
                    permission_scopes: { "manage_adjustments" => "business_wide" })
      wide_mgr  = create(:user, business: business, permission_role: role)
      unmanaged = create(:user, business: business, first_name: "Unmanaged", last_name: "Person")
      sign_in wide_mgr

      get new_adjustment_path
      expect(response.body).to include("Unmanaged Person")
    end

    it "limits a branch-scoped adjustments manager to their branch" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_payroll manage_adjustments],
                    permission_scopes: { "manage_adjustments" => "branch" })
      restricted = create(:user, business: business, permission_role: role)
      r_branch   = create(:branch, business: business, branch_manager_id: restricted.id)
      report     = create(:user, business: business, first_name: "My", last_name: "Report")
      create(:shift_assignment, user: report, branch: r_branch, shift: shift)
      create(:user, business: business, first_name: "Outside", last_name: "Scope")
      sign_in restricted

      get new_adjustment_path
      expect(response.body).to include("My Report")
      expect(response.body).not_to include("Outside Scope")
    end
  end

  describe "POST /adjustments (create)" do
    it "creates the adjustment as Pending and does NOT auto-approve the creator" do
      sign_in manager
      expect {
        post adjustments_path, params: create_params
      }.to change(PayrollAdjustment, :count).by(1)

      adj = PayrollAdjustment.last
      expect(adj.review_status).to eq("pending_review")
      expect(adj.created_by).to eq(manager)
      expect(adj.approved_by).to be_nil
      expect(adj.approved_at).to be_nil
      expect(adj.period_month).to eq(7)
      expect(adj.period_year).to eq(2026)
    end

    it "auto-approves an adjustment created by the business owner" do
      owner = create(:user, :owner, business: business)
      sign_in owner

      expect {
        post adjustments_path, params: create_params
      }.to change(PayrollAdjustment, :count).by(1)

      adj = PayrollAdjustment.last
      expect(adj.review_status).to eq("approved")
      expect(adj.created_by).to eq(owner)
      expect(adj.approved_by).to eq(owner)
      expect(adj.approved_at).to be_present
      expect(adj.reviewed_by).to eq(owner)
    end

    it "blocks creation for a paid period with the processed message" do
      draft_period.update_column(:status, "paid")
      sign_in manager

      expect {
        post adjustments_path, params: create_params
      }.not_to change(PayrollAdjustment, :count)

      expect(response.body).to include(I18n.t("adjustments.errors.period_processed"))
    end
  end

  describe "PATCH /adjustments/:id/approve" do
    let!(:adjustment) do
      create(:payroll_adjustment, :cash_incentive,
             payroll_period: draft_period, business: business,
             user: employee, created_by: manager, review_status: :pending_review)
    end

    it "forbids the creator from approving their own adjustment" do
      sign_in manager
      patch approve_adjustment_path(adjustment)

      expect(adjustment.reload.review_status).to eq("pending_review")
      expect(adjustment.approved_by).to be_nil
    end

    it "allows a different authorised approver to approve" do
      sign_in approver
      patch approve_adjustment_path(adjustment)

      adjustment.reload
      expect(adjustment.review_status).to eq("approved")
      expect(adjustment.approved_by).to eq(approver)
      expect(adjustment.approved_by).not_to eq(adjustment.created_by)
    end

    context "when a PayrollEntry already exists for the employee and period" do
      let!(:entry) do
        create(:payroll_entry,
               payroll_period: draft_period,
               user:           employee,
               base_salary:    5_000.0,
               net_salary:     5_000.0,
               total_bonuses:  0.0,
               total_deductions: 0.0)
      end

      it "materialises the approval into the existing entry immediately" do
        sign_in approver
        patch approve_adjustment_path(adjustment)

        entry.reload
        expect(entry.payroll_line_items.where(item_type: "cash_incentive").count).to eq(1)
        expect(entry.total_bonuses).to eq(500.0)
        expect(entry.net_salary).to eq(5_500.0)
      end

      context "with a manual_deduction" do
        let!(:deduction_adj) do
          create(:payroll_adjustment, :manual_deduction,
                 payroll_period: draft_period, business: business,
                 user: employee, created_by: manager, review_status: :pending_review,
                 amount: 200.0)
        end

        it "subtracts the deduction from net_salary on approval" do
          sign_in approver
          patch approve_adjustment_path(deduction_adj)

          entry.reload
          expect(entry.payroll_line_items.where(item_type: "manual_deduction").count).to eq(1)
          expect(entry.total_deductions).to eq(200.0)
          expect(entry.net_salary).to eq(4_800.0)
        end
      end
    end
  end

  describe "Bulk approve / reject" do
    let!(:adj_a) do
      create(:payroll_adjustment, :cash_incentive, business: business, user: employee,
             created_by: manager, payroll_period: draft_period, review_status: :pending_review)
    end
    let!(:adj_b) do
      create(:payroll_adjustment, :commission, business: business, user: employee,
             created_by: manager, payroll_period: draft_period, review_status: :pending_review)
    end
    let!(:adj_done) do
      create(:payroll_adjustment, :cash_incentive, :approved, business: business, user: employee,
             created_by: manager, payroll_period: draft_period)
    end

    it "POST bulk_approve approves the selected pending rows and reports counts" do
      sign_in approver
      post bulk_approve_adjustments_path,
           params: { adjustment_ids: [ adj_a.id, adj_b.id, adj_done.id ] }

      expect(response).to redirect_to(adjustments_path)
      expect(adj_a.reload.review_status).to eq("approved")
      expect(adj_a.approved_by).to eq(approver)
      expect(adj_b.reload.review_status).to eq("approved")
      # adj_done was already approved → skipped, not re-touched.
      expect(flash[:notice]).to include("Approved: 2", "Skipped: 1", "Failed: 0")
    end

    it "POST bulk_reject rejects the selected pending rows" do
      sign_in approver
      post bulk_reject_adjustments_path, params: { adjustment_ids: [ adj_a.id ] }

      expect(adj_a.reload.review_status).to eq("rejected")
      expect(adj_a.rejected_by).to eq(approver)
      expect(flash[:notice]).to include("Rejected: 1")
    end

    it "counts an adjustment the reviewer created themselves as failed (creator ≠ approver)" do
      own = create(:payroll_adjustment, :cash_incentive, business: business, user: employee,
                   created_by: approver, payroll_period: draft_period, review_status: :pending_review)
      sign_in approver
      post bulk_approve_adjustments_path, params: { adjustment_ids: [ own.id ] }

      expect(own.reload.review_status).to eq("pending_review")
      # Nothing succeeded → surfaced as an alert rather than a notice.
      expect(flash[:alert]).to include("Approved: 0", "Failed: 1")
    end

    it "forbids an employee from using the bulk endpoint and changes nothing" do
      sign_in employee
      post bulk_approve_adjustments_path, params: { adjustment_ids: [ adj_a.id, adj_b.id ] }

      expect(response).to redirect_to(root_path)
      expect(adj_a.reload.review_status).to eq("pending_review")
      expect(adj_b.reload.review_status).to eq("pending_review")
    end

    it "reports when nothing actionable was selected" do
      sign_in approver
      post bulk_approve_adjustments_path, params: { adjustment_ids: [] }
      expect(flash[:alert]).to eq(I18n.t("adjustments.bulk.none_selected"))
    end
  end

  describe "GET /adjustments (index)" do
    let!(:adj_june) do
      create(:payroll_adjustment, :cash_incentive, business: business, user: employee,
             created_by: manager, payroll_period: nil, period_month: 6, period_year: 2026)
    end
    let!(:adj_aug) do
      create(:payroll_adjustment, :commission, business: business, user: employee,
             created_by: manager, payroll_period: nil, period_month: 8, period_year: 2026)
    end

    it "shows adjustments across all periods by default (no period filter)" do
      sign_in approver
      get adjustments_path

      expect(response).to have_http_status(:ok)
      # Both periods' rows are present (linked by their detail paths).
      expect(response.body).to include(adjustment_path(adj_june))
      expect(response.body).to include(adjustment_path(adj_aug))
    end

    it "lets the creator see adjustments they created and offers a details link" do
      sign_in manager
      get adjustments_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(adjustment_path(adj_june))
      expect(response.body).to include(I18n.t("adjustments.view_details"))
    end

    it "shows the bulk Approve/Reject controls to a reviewer" do
      sign_in approver
      get adjustments_path

      expect(response.body).to include('data-controller="adjustment-bulk-review"')
      expect(response.body).to include("bulk-check-all")
      expect(response.body).to include(I18n.t("adjustments.bulk.approve_selected"))
      expect(response.body).to include(I18n.t("adjustments.bulk.reject_selected"))
    end

    context "as a regular employee" do
      let!(:my_approved) do
        create(:payroll_adjustment, :cash_incentive, :approved, business: business, user: employee,
               created_by: manager, payroll_period: nil, period_month: 6, period_year: 2026)
      end
      let!(:my_pending) do
        create(:payroll_adjustment, :commission, business: business, user: employee,
               created_by: manager, payroll_period: nil, period_month: 7, period_year: 2026)
      end
      let!(:coworker_approved) do
        coworker = create(:user, business: business)
        create(:payroll_adjustment, :cash_incentive, :approved, business: business, user: coworker,
               created_by: manager, payroll_period: nil, period_month: 6, period_year: 2026)
      end

      it "can open the Adjustments page and sees ONLY their own approved adjustments" do
        sign_in employee
        get adjustments_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(adjustment_path(my_approved))       # own + approved
        expect(response.body).not_to include(adjustment_path(my_pending))    # own but pending → hidden
        expect(response.body).not_to include(adjustment_path(coworker_approved)) # another employee → hidden
      end

      it "does not expose analytics, creation, or bulk-review actions to the employee" do
        sign_in employee
        get adjustments_path

        expect(response.body).not_to include('class="adj-stats"')                   # Analytics & Reports hidden
        expect(response.body).not_to include(new_adjustment_path)                   # cannot create
        expect(response.body).not_to include('data-controller="adjustment-bulk-review"') # no bulk UI
        expect(response.body).not_to include("bulk-check-all")
      end

      it "shows an Adjustments link in the employee sidebar navigation" do
        sign_in employee
        get root_path # dashboard — renders the application layout + sidebar

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("href=\"#{adjustments_path}\"")
        expect(response.body).to include(I18n.t("nav.adjustments"))
      end
    end

    # Analytics & Reports (the aggregate stats strip + insights) are Business-scope only.
    context "Adjustment Analytics & Reports visibility" do
      it "shows analytics to the business owner" do
        owner = create(:user, :owner, business: business)
        sign_in owner
        get adjustments_path

        expect(response.body).to include('class="adj-stats"')
      end

      it "shows analytics to a business-scope admin (accountant)" do
        sign_in approver
        get adjustments_path

        expect(response.body).to include('class="adj-stats"')
      end

      it "hides analytics from a branch-scope manager" do
        sign_in manager
        get adjustments_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('class="adj-stats"')
        expect(response.body).not_to include('class="adj-insights"')
      end
    end
  end

  describe "GET /adjustments/:id (show)" do
    let!(:adjustment) do
      create(:payroll_adjustment, :cash_incentive,
             payroll_period: draft_period, business: business,
             user: employee, created_by: manager, review_status: :pending_review,
             reason: "Quarterly bonus payout")
    end

    it "renders the details page for the creator with the audit timeline" do
      sign_in manager
      get adjustment_path(adjustment)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Quarterly bonus payout")
      expect(response.body).to include(I18n.t("adjustments.show.timeline.heading"))
      expect(response.body).to include(I18n.t("adjustments.show.timeline.created"))
      expect(response.body).to include(I18n.t("adjustments.show.timeline.submitted"))
    end

    it "404s for the subject employee while the adjustment is still pending" do
      # The subject employee may only view their own adjustments once approved.
      sign_in employee
      get adjustment_path(adjustment) # pending_review
      expect(response).to have_http_status(:not_found)
    end

    it "renders for the subject employee once the adjustment is approved" do
      adjustment.update_columns(review_status: "approved",
                                approved_by_id: approver.id, approved_at: Time.current,
                                reviewed_by_id: approver.id, reviewed_at: Time.current)
      sign_in employee
      get adjustment_path(adjustment)
      expect(response).to have_http_status(:ok)
    end

    it "renders for an authorised reviewer" do
      sign_in approver
      get adjustment_path(adjustment)
      expect(response).to have_http_status(:ok)
    end

    it "404s for an unrelated employee with no payroll permissions" do
      outsider = create(:user, business: business)
      sign_in outsider
      get adjustment_path(adjustment)
      expect(response).to have_http_status(:not_found)
    end

    context "when the adjustment is already approved" do
      before do
        adjustment.update_columns(review_status: "approved",
                                  approved_by_id: approver.id, approved_at: Time.current,
                                  reviewed_by_id: approver.id, reviewed_at: Time.current)
      end

      it "shows the locked notice and offers no approve/remove actions" do
        sign_in approver
        get adjustment_path(adjustment)

        expect(response.body).to include(I18n.t("adjustments.show.approved_by"))
        expect(response.body).to include(approver.full_name)
        # Approved adjustments are immutable — no approve or remove buttons.
        expect(response.body).not_to include(approve_adjustment_path(adjustment))
        expect(response.body).not_to include(I18n.t("adjustments.remove"))
      end
    end
  end
end
