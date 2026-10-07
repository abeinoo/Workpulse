require "rails_helper"

# Characterization (Pilot 8 — Workforce Employee Insurance Profile, M1) —
# CURRENT behaviour of the insurance screens: the edit / update action
# (Admin::EmployeeInsuranceProfilesController) and the Social Insurance card on
# the employee page (admin/users#show).
#
# The payroll notice on the edit form (none / active / mixed / finalized) is
# pinned by spec/requests/admin/employee_insurance_profiles_spec.rb; SEC-P8-1 and
# SEC-P8-2 by spec/requests/security/employee_insurance_profile_deletion_spec.rb
# and _scope_spec.rb. This file adds the response contract, the parameters, the
# card's contents and the per-scope matrix as seen on the employee page.
RSpec.describe "Characterization: employee insurance screens", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:employee_a) { create(:user, business: business) }
  let!(:employee_b) { create(:user, business: business) }

  # view_employees business-wide, so every employee page opens; the insurance
  # scope varies.
  def insurance_user(scope, manage: true)
    permissions = %i[view_employees view_employee_insurance] + (manage ? [ :manage_employee_insurance ] : [])
    scopes = { "view_employees" => "business", "view_employee_insurance" => scope }
    scopes["manage_employee_insurance"] = scope if manage
    api_user_with(business, *permissions, scopes: scopes)
  end

  def profile_for(user, **attrs)
    EmployeeInsuranceProfile.create!({ user: user, business: user.business, created_by: user, insured: true,
                                       employee_contribution_amount: 450, employer_contribution_amount: 1_250,
                                       insurance_start_date: Date.new(2026, 1, 1), insurance_number: "INS-77" }.merge(attrs))
  end

  def card(html = response.body)
    Nokogiri::HTML(html).css(".card").find { |c| c.at_css(".card-title")&.text == I18n.t("insurance.card_title") }
  end

  def edit_link?(user) = card.css("a").any? { |a| a["href"] == edit_admin_user_employee_insurance_profile_path(user) }

  before do
    create(:shift_assignment, business: business, user: employee_a, branch: branch_a)
    create(:shift_assignment, business: business, user: employee_b, branch: branch_b)
  end

  describe "update (business-scoped manager)" do
    let(:manager) { insurance_user("business") }

    before { sign_in manager }

    it "saves, redirects to the employee page with the success notice (en key present)" do
      patch admin_user_employee_insurance_profile_path(employee_a),
            params: { employee_insurance_profile: { insured: "1", employee_contribution_amount: "300.50",
                                                    employer_contribution_amount: "900", insurance_start_date: "2026-02-01",
                                                    insurance_end_date: "", insurance_number: "N-1", notes: "n" } }

      expect(response).to redirect_to(admin_user_path(employee_a))
      expect(flash[:notice]).to eq(I18n.t("flash.insurance_profile_updated"))
      expect(employee_a.reload.employee_insurance_profile).to have_attributes(
        insured: true, employee_contribution_amount: BigDecimal("300.50"), employer_contribution_amount: 900,
        insurance_start_date: Date.new(2026, 2, 1), insurance_end_date: nil, insurance_number: "N-1", notes: "n",
        business_id: business.id, created_by_id: manager.id
      )
    end

    it "ignores business_id, user_id and created_by_id in the parameters" do
      patch admin_user_employee_insurance_profile_path(employee_a),
            params: { employee_insurance_profile: { insured: "0", business_id: other.id, user_id: employee_b.id,
                                                    created_by_id: employee_b.id } }

      profile = employee_a.reload.employee_insurance_profile
      expect(profile).to have_attributes(business_id: business.id, user_id: employee_a.id, created_by_id: manager.id)
      expect(employee_b.reload.employee_insurance_profile).to be_nil
    end

    it "an invalid submission re-renders the form with 422 and saves nothing" do
      profile = profile_for(employee_a)
      patch admin_user_employee_insurance_profile_path(employee_a),
            params: { employee_insurance_profile: { insurance_start_date: "2026-05-01", insurance_end_date: "2026-04-01" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("must be on or after the start date")
      expect(profile.reload.insurance_start_date).to eq(Date.new(2026, 1, 1))
    end

    it "the edit form shows the existing values" do
      profile_for(employee_a)
      get edit_admin_user_employee_insurance_profile_path(employee_a)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("INS-77", "450.0", "1250.0")
    end
  end

  describe "the Social Insurance card on the employee page" do
    it "a manager sees status, both contributions, dates, number and the Edit button" do
      profile_for(employee_a, insurance_end_date: Date.new(2026, 12, 31))
      sign_in insurance_user("business")
      get admin_user_path(employee_a)

      text = card.text
      expect(text).to include(I18n.t("insurance.insured"), I18n.t("insurance.employee_contribution"),
                              I18n.t("insurance.employer_contribution"), I18n.t("insurance.insurance_number"), "INS-77")
      expect(edit_link?(employee_a)).to be(true)
    end

    it "an open-ended profile shows a dash for the end date; no number → no number row" do
      profile_for(employee_a, insurance_number: nil)
      sign_in insurance_user("business")
      get admin_user_path(employee_a)

      expect(card.text).to include("—")
      expect(card.text).not_to include(I18n.t("insurance.insurance_number"))
    end

    it "a view-only holder sees the employee contribution but not the employer contribution, and no Edit button" do
      profile_for(employee_a)
      sign_in insurance_user("business", manage: false)
      get admin_user_path(employee_a)

      expect(card.text).to include(I18n.t("insurance.employee_contribution"))
      expect(card.text).not_to include(I18n.t("insurance.employer_contribution"))
      expect(edit_link?(employee_a)).to be(false)
    end

    it "no profile, or not insured: 'Not insured.'" do
      profile_for(employee_b, insured: false)
      sign_in insurance_user("business")

      get admin_user_path(employee_a)
      expect(card.text).to include(I18n.t("insurance.not_insured"))
      get admin_user_path(employee_b)
      expect(card.text).to include(I18n.t("insurance.not_insured"))
    end

    it "a user without any insurance permission sees no card" do
      profile_for(employee_a)
      sign_in api_user_with(business, :view_employees, scopes: { "view_employees" => "business" })
      get admin_user_path(employee_a)

      expect(response).to have_http_status(:ok)
      expect(card).to be_nil
    end

    describe "Edit button per insurance scope (follows the SEC-P8-2 policy)" do
      let(:branch_manager) { insurance_user("branch") }

      before { branch_a.update_column(:branch_manager_id, branch_manager.id) }

      it "branch scope: shown for an employee of the managed branch, not for another branch" do
        sign_in branch_manager
        get admin_user_path(employee_a)
        expect(edit_link?(employee_a)).to be(true)
        get admin_user_path(employee_b)
        expect(edit_link?(employee_b)).to be(false)
      end

      it "self scope: not shown on another employee's page" do
        sign_in insurance_user("self")
        get admin_user_path(employee_a)
        expect(edit_link?(employee_a)).to be(false)
      end

      it "business scope: shown for every employee of the business" do
        sign_in insurance_user("business")
        [ employee_a, employee_b ].each do |user|
          get admin_user_path(user)
          expect(edit_link?(user)).to be(true)
        end
      end
    end

    describe "P8-D1 (known debt, pinned, not fixed): the card ignores the insurance scope" do
      it "a holder scoped to self (view or manage) still sees another employee's card and amounts" do
        profile_for(employee_b)
        [ insurance_user("self", manage: false), insurance_user("self") ].each do |viewer|
          sign_in viewer
          get admin_user_path(employee_b)

          expect(card.text).to include(I18n.t("insurance.insured"), "INS-77")
          expect(EmployeeInsuranceProfilePolicy::Scope.new(viewer, EmployeeInsuranceProfile).resolve)
            .not_to include(employee_b.employee_insurance_profile)
        end
      end

      it "a manager scoped to self also sees the employer contribution of another employee" do
        profile_for(employee_b)
        sign_in insurance_user("self")
        get admin_user_path(employee_b)

        expect(card.text).to include(I18n.t("insurance.employer_contribution"))
      end
    end
  end

  # Requests that end in a rescued 404 are kept one per example (the test session
  # does not survive the rescued exception).
  describe "cross-business (404, nothing created)" do
    let(:foreign) { create(:user, business: other) }

    before { sign_in insurance_user("business") }

    it "the edit form of another business's employee" do
      get edit_admin_user_employee_insurance_profile_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "an update for another business's employee" do
      expect do
        patch admin_user_employee_insurance_profile_path(foreign),
              params: { employee_insurance_profile: { insured: "1", insurance_start_date: "2026-01-01" } }
      end.not_to change(EmployeeInsuranceProfile, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
