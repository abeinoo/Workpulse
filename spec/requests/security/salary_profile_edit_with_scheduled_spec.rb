require "rails_helper"

# Regression: entering a future-dated profile moved the `active` flag to it, and
# SalaryProfilePolicy#update? required `active` — so while a raise was scheduled
# no profile was correctable and "Edit Active Profile" disappeared. The profile
# in force today stays correctable; the scheduled one never is, and neither
# view_salary_history nor anything else but the existing update rule grants it.
RSpec.describe "Editing the current salary profile while a change is scheduled", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) do
    create(:user, business: business).tap do |u|
      create(:shift_assignment, business: business, user: u, branch: branch,
                                effective_from: 1.month.ago.to_date, effective_to: nil)
    end
  end

  let!(:previous)  { create(:salary_profile, user: employee, base_amount: 423.08, effective_from: 6.months.ago.to_date) }
  let!(:current)   { create(:salary_profile, user: employee, base_amount: 461.53, effective_from: 5.months.ago.to_date) }
  let!(:scheduled) { create(:salary_profile, user: employee, base_amount: 600, effective_from: 1.month.from_now.to_date) }

  def manager(*permissions)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      branch.update_column(:branch_manager_id, u.id)
    end
  end

  let(:editor) { manager(:view_employees, :view_payroll, :manage_salary_profiles) }

  def edit_path(profile) = edit_admin_user_salary_profile_path(employee, profile)
  def edit_links = Nokogiri::HTML(response.body).css("a").map { _1["href"] }.select { _1&.match?(%r{/salary_profiles/\d+/edit}) }

  def patch_amount(profile, amount)
    patch admin_user_salary_profile_path(employee, profile), params: { salary_profile: { base_amount: amount.to_s } }
  end

  it "keeps the flag on the scheduled profile (stored semantics unchanged)" do
    expect([ previous, current, scheduled ].map { _1.reload.active? }).to eq([ false, false, true ])
  end

  describe "the employee page" do
    it "shows the edit action for the profile in force, never for the scheduled one" do
      sign_in editor
      get admin_user_path(employee)

      expect(edit_links).to eq([ edit_path(current) ])
      expect(response.body).to include(I18n.t("admin.users.edit_active_profile"))
      expect(response.body).to include(new_admin_user_salary_profile_path(employee))
    end

    it "shows the edit action to the owner too" do
      sign_in owner
      get admin_user_path(employee)
      expect(edit_links).to eq([ edit_path(current) ])
    end

    it "with history, still one edit action — on the current card, none in the history rows" do
      sign_in manager(:view_employees, :view_payroll, :manage_salary_profiles, :view_salary_history)
      get admin_user_path(employee)

      expect(edit_links).to eq([ edit_path(current) ])
      expect(Nokogiri::HTML(response.body).css("tr[data-salary-history-status] a")).to be_empty
    end

    {
      "view_payroll without manage_salary_profiles" => %i[view_employees view_payroll],
      "manage_salary_profiles without view_payroll" => %i[view_employees manage_salary_profiles],
      "view_salary_history without manage_salary_profiles" => %i[view_employees view_payroll view_salary_history]
    }.each do |label, permissions|
      it "shows no edit action for #{label}" do
        sign_in manager(*permissions)
        get admin_user_path(employee)
        expect(edit_links).to be_empty
      end
    end

    it "targets the new profile once its date arrives" do
      sign_in editor
      travel_to(scheduled.effective_from.in_time_zone(business.timezone) + 12.hours) { get admin_user_path(employee) }
      expect(edit_links).to eq([ edit_path(scheduled) ])
    end
  end

  describe "correcting in place" do
    before { sign_in editor }

    it "corrects the profile in force, audited, leaving the others and the active flag alone" do
      get edit_path(current)
      expect(response).to have_http_status(:ok)

      expect { patch_amount(current, 470) }.to change { AuditLog.where(action: "update", auditable: current).count }.by(1)
      expect(response).to redirect_to(admin_user_path(employee))
      expect(current.reload).to have_attributes(base_amount: 470, active: false)
      expect(scheduled.reload).to have_attributes(base_amount: 600, active: true)
      expect(previous.reload.base_amount).to eq(423.08)
    end

    it "refuses the scheduled profile" do
      patch_amount(scheduled, 1)
      expect(scheduled.reload.base_amount).to eq(600)
    end

    it "refuses the previous profile" do
      patch_amount(previous, 1)
      expect(previous.reload.base_amount).to eq(423.08)
    end

    it "refuses moving the profile in force onto the scheduled date" do
      patch admin_user_salary_profile_path(employee, current),
            params: { salary_profile: { effective_from: scheduled.effective_from.iso8601 } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(current.reload.effective_from).to eq(5.months.ago.to_date)
    end

    it "refuses an editor without view_payroll or with history only" do
      # One at a time: each becomes the branch's manager, so the employee is in scope.
      [ %i[view_employees manage_salary_profiles], %i[view_employees view_payroll view_salary_history] ].each do |permissions|
        sign_in manager(*permissions)
        patch_amount(current, 1)
        expect(current.reload.base_amount).to eq(461.53)
      end
    end
  end

  describe "without a scheduled profile (unchanged)" do
    before { scheduled.destroy! && current.update_column(:active, true) }

    it "shows and allows editing the current profile only" do
      sign_in editor
      get admin_user_path(employee)
      expect(edit_links).to eq([ edit_path(current) ])

      patch_amount(current, 480)
      expect(current.reload.base_amount).to eq(480)
      patch_amount(previous, 1)
      expect(previous.reload.base_amount).to eq(423.08)
    end
  end

  # The mobile API corrects through the same policy, Salary::ProfileCorrector and
  # model rules as the web; it never accepts effective_from or salary_type.
  describe "the API update (same rule as the web)" do
    def api_patch(profile, attributes, user: employee)
      patch "/api/v1/users/#{user.id}/salary_profiles/#{profile.id}", params: { salary_profile: attributes }, as: :json
    end

    def api_data = JSON.parse(response.body)["data"]
    def salary_views = AuditLog.where(action: "view_salary")

    before { sign_in editor }

    it "corrects the profile in force, audited, leaving the scheduled one and the active flag alone" do
      expect { api_patch(current, { base_amount: "465" }) }
        .to change { AuditLog.where(action: "update", auditable: current).count }.by(1)
        .and change { salary_views.where("metadata->>'source' = ?", "api_salary_profile_update").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(api_data).to include("id" => current.id, "active" => false)
      expect(current.reload).to have_attributes(base_amount: 465, active: false)
      expect(scheduled.reload).to have_attributes(base_amount: 600, active: true)
    end

    it "refuses the scheduled profile" do
      api_patch(scheduled, { base_amount: "1" })
      expect(response).to have_http_status(:forbidden)
      expect(scheduled.reload.base_amount).to eq(600)
    end

    it "refuses the previous profile" do
      api_patch(previous, { base_amount: "1" })
      expect(response).to have_http_status(:forbidden)
      expect(previous.reload.base_amount).to eq(423.08)
    end

    it "never moves the profile in force onto or past the scheduled date (effective_from is not accepted)" do
      [ scheduled.effective_from, scheduled.effective_from + 1.month ].each do |date|
        api_patch(current, { effective_from: date.iso8601, base_amount: "466" })
        expect(current.reload.effective_from).to eq(5.months.ago.to_date)
      end
      expect(current.base_amount).to eq(466)
      expect(SalaryProfile.current_for(employee)).to eq(current)
    end

    it "refuses viewers without manage_salary_profiles, with history only, or out of scope" do
      # One at a time: each becomes the branch's manager, so the employee is in scope.
      [ %i[view_employees view_payroll], %i[view_employees view_payroll view_salary_history] ].each do |permissions|
        sign_in manager(*permissions)
        api_patch(current, { base_amount: "1" })
        expect(response).to have_http_status(:forbidden)
      end

      other_branch_employee = create(:user, business: business).tap do |u|
        create(:shift_assignment, business: business, user: u, branch: create(:branch, business: business),
                                  effective_from: 1.month.ago.to_date, effective_to: nil)
      end
      other_current = create(:salary_profile, user: other_branch_employee, effective_from: 1.month.ago.to_date)
      sign_in editor
      api_patch(other_current, { base_amount: "1" }, user: other_branch_employee)
      expect(response.status).to be_in([ 403, 404 ])
      expect(other_current.reload.base_amount).to eq(5_000)

      expect(current.reload.base_amount).to eq(461.53)
    end

    it "keeps the index current-only for the editor" do
      get "/api/v1/users/#{employee.id}/salary_profiles", as: :json
      expect(api_data.map { _1["id"] }).to eq([ current.id ])
    end
  end
end
