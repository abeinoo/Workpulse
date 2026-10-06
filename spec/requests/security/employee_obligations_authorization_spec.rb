require "rails_helper"

# Employee Obligations authorization (found in Milestone 2 Pilot 2 M0; fixed
# before characterization):
#
# SEC-M2-10  A manage_obligations holder could cancel, pause, resume, edit
#            (e.g. switch off auto_deduct) or postpone their OWN obligation.
#            Changing one's own debt is now refused; the owner is the only exception.
# SEC-M2-11  With no manage_obligations scope configured, the policy scope was
#            the whole business. It now follows the hierarchy default
#            (EmployeeScope#relation, like the other payroll policies).
# SEC-M2-4 follow-up
#            Create (and reassignment on update) did not check the target
#            employee against the actor's scope. Out-of-scope targets are refused.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Security: employee obligation authorization", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }

  def employee_at(branch)
    create(:user, business: business).tap do |user|
      create(:shift_assignment, user: user, branch: branch, shift: shift)
    end
  end

  def obligation_for(user, **attributes)
    create(:employee_obligation, business: business, user: user, created_by: owner,
                                 total_amount: 5_000, remaining_amount: 5_000, installment_amount: 500, **attributes)
  end

  def manager(scope: nil)
    scopes = scope ? { "manage_obligations" => scope } : {}
    api_user_with(business, :view_employees, :manage_obligations, scopes: scopes)
      .tap { |user| branch_a.update_column(:branch_manager_id, user.id) }
  end

  def create_params(user)
    { employee_obligation: { user_id: user.id, obligation_type: "cash_loan", title: "Advance loan",
                             total_amount: 1_000, installment_amount: 100,
                             start_month: Date.current.month, start_year: Date.current.year } }
  end

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  let(:emp_a) { employee_at(branch_a) }
  let(:emp_b) { employee_at(branch_b) }

  # ── SEC-M2-10 ────────────────────────────────────────────────────────────
  describe "managing one's own obligation (SEC-M2-10)" do
    let(:actor) { manager(scope: "branch") }
    let!(:own)  { obligation_for(actor) }

    before { sign_in actor }

    it "cannot cancel it" do
      patch cancel_admin_employee_obligation_path(own)
      expect_denied
      expect(own.reload).to be_active
    end

    it "cannot pause it" do
      patch pause_admin_employee_obligation_path(own)
      expect_denied
      expect(own.reload).to be_active
    end

    it "cannot resume it" do
      own.update_column(:status, "paused")
      patch resume_admin_employee_obligation_path(own)
      expect_denied
      expect(own.reload).to be_paused
    end

    it "cannot switch off auto-deduction (or otherwise edit it)" do
      patch admin_employee_obligation_path(own), params: { employee_obligation: { auto_deduct: "0" } }
      expect_denied
      expect(own.reload.auto_deduct).to be(true)
    end

    it "cannot open the edit form" do
      get edit_admin_employee_obligation_path(own)
      expect_denied
    end

    it "cannot postpone an installment" do
      expect {
        patch postpone_admin_employee_obligation_path(own),
              params: { year: own.start_year, month: own.start_month, postponement_type: "extend_loan" }
      }.not_to change(ObligationPostponement, :count)
      expect_denied
    end

    it "can still view it, without change actions" do
      get admin_employee_obligation_path(own)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(cancel_admin_employee_obligation_path(own))
      expect(response.body).not_to include(pause_admin_employee_obligation_path(own))
      expect(response.body).not_to include(edit_admin_employee_obligation_path(own))
    end

    it "can still manage another in-scope employee's obligation" do
      theirs = obligation_for(emp_a)

      get admin_employee_obligation_path(theirs)
      expect(response.body).to include(cancel_admin_employee_obligation_path(theirs))

      patch pause_admin_employee_obligation_path(theirs)
      expect(theirs.reload).to be_paused

      patch resume_admin_employee_obligation_path(theirs)
      expect(theirs.reload).to be_active

      patch admin_employee_obligation_path(theirs), params: { employee_obligation: { auto_deduct: "0" } }
      expect(theirs.reload.auto_deduct).to be(false)

      patch cancel_admin_employee_obligation_path(theirs)
      expect(theirs.reload).to be_cancelled
    end

    it "the owner may still manage the owner's own obligation" do
      owners_own = obligation_for(owner)
      sign_in owner
      patch pause_admin_employee_obligation_path(owners_own)
      expect(owners_own.reload).to be_paused
    end
  end

  # ── SEC-M2-11 ────────────────────────────────────────────────────────────
  describe "no configured scope (SEC-M2-11)" do
    let(:actor) { manager }

    before { sign_in actor }

    it "does not list another branch's obligations" do
      obligation_for(emp_a, title: "Branch A loan")
      obligation_for(emp_b, title: "Branch B loan")

      get admin_employee_obligations_path

      titles = Nokogiri::HTML(response.body).css(".obl-title").map { |node| node.text.strip }
      expect(titles).to include("Branch A loan")
      expect(titles).not_to include("Branch B loan")
    end

    it "cannot view another branch's obligation (404)" do
      get admin_employee_obligation_path(obligation_for(emp_b))
      expect(response).to have_http_status(:not_found)
    end

    it "cannot cancel another branch's obligation (404)" do
      theirs = obligation_for(emp_b)
      patch cancel_admin_employee_obligation_path(theirs)
      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).to be_active
    end

    it "still manages the managed branch's obligations" do
      theirs = obligation_for(emp_a)
      patch cancel_admin_employee_obligation_path(theirs)
      expect(theirs.reload).to be_cancelled
    end
  end

  describe "explicit scopes" do
    it "business scope reaches every branch of the business" do
      sign_in manager(scope: "business")
      theirs = obligation_for(emp_b)
      patch cancel_admin_employee_obligation_path(theirs)
      expect(theirs.reload).to be_cancelled
    end

    it "branch scope cannot view another branch's obligation (404)" do
      sign_in manager(scope: "branch")
      get admin_employee_obligation_path(obligation_for(emp_b))
      expect(response).to have_http_status(:not_found)
    end

    it "never reaches another business's obligation (404), even business-wide" do
      foreign = create(:employee_obligation, business: other)
      sign_in manager(scope: "business")
      get admin_employee_obligation_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── SEC-M2-4 follow-up ───────────────────────────────────────────────────
  describe "creating for an employee (SEC-M2-4 follow-up)" do
    it "allows a same-business, in-scope employee" do
      sign_in manager(scope: "branch")
      expect { post admin_employee_obligations_path, params: create_params(emp_a) }.to change(EmployeeObligation, :count).by(1)
      expect(EmployeeObligation.last.user).to eq(emp_a)
    end

    it "refuses a same-business employee outside an explicit branch scope" do
      sign_in manager(scope: "branch")
      expect { post admin_employee_obligations_path, params: create_params(emp_b) }.not_to change(EmployeeObligation, :count)
      expect_denied
    end

    it "refuses a same-business employee outside the hierarchy when no scope is configured" do
      sign_in manager
      expect { post admin_employee_obligations_path, params: create_params(emp_b) }.not_to change(EmployeeObligation, :count)
      expect_denied
    end

    it "refuses an employee of another business" do
      sign_in manager(scope: "business")
      expect { post admin_employee_obligations_path, params: create_params(create(:user, business: other)) }
        .not_to change(EmployeeObligation, :count)
      expect(response).to redirect_to(root_path).or have_http_status(:unprocessable_content)
    end

    it "refuses opening the form for an out-of-scope employee and only offers in-scope employees" do
      actor = manager(scope: "branch")
      emp_a
      emp_b
      sign_in actor

      get new_admin_employee_obligation_path(user_id: emp_b.id)
      expect_denied

      get new_admin_employee_obligation_path
      options = Nokogiri::HTML(response.body).css("select[name='employee_obligation[user_id]'] option").map { |o| o["value"] }
      expect(options).to include(emp_a.id.to_s)
      expect(options).not_to include(emp_b.id.to_s)
    end

    it "refuses moving an obligation to an out-of-scope employee on update" do
      sign_in manager(scope: "branch")
      theirs = obligation_for(emp_a)
      patch admin_employee_obligation_path(theirs), params: { employee_obligation: { user_id: emp_b.id } }
      expect_denied
      expect(theirs.reload.user).to eq(emp_a)
    end
  end
end
