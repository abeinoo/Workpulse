require "rails_helper"

# Characterization — branch administration, business settings and locale
# endpoints (CURRENT behaviour). Branch-type and terminal-ID behaviour is in
# spec/requests/admin/branches_spec.rb; settings starting-number behaviour in
# spec/requests/admin/settings_spec.rb; preference switching in
# spec/requests/preferences_spec.rb.
RSpec.describe "Characterization: Organization & Access branches and settings", type: :request do
  let(:business)       { create(:business, timezone: "Asia/Riyadh") }
  let(:other_business) { create(:business) }
  let!(:owner)         { create(:user, :owner, business: business) }

  describe "branches" do
    before { sign_in owner }

    it "index lists only the business's branches" do
      own     = create(:branch, business: business, name: "Own Branch")
      foreign = create(:branch, business: other_business, name: "Foreign Branch")
      get admin_branches_path
      expect(response.body).to include(own.name)
      expect(response.body).not_to include(foreign.name)
    end

    it "create always assigns the actor's business (business_id in params is ignored)" do
      post admin_branches_path, params: { branch: { name: "New Branch", branch_type: "sales", business_id: other_business.id } }
      branch = Branch.find_by!(name: "New Branch")
      expect(branch.business_id).to eq(business.id)
      expect(response).to redirect_to(admin_branch_path(branch))
    end

    # BUG-026: deactivation goes through PATCH deactivate (reason, last-active
    # rule, audit — spec/requests/admin/branch_lifecycle_spec.rb); the edit form
    # no longer changes `active`.
    it "new branches are active by default and are deactivated only through the lifecycle action" do
      create(:branch, business: business, name: "Main", active: true)
      post admin_branches_path, params: { branch: { name: "Toggle Branch", branch_type: "sales" } }
      branch = Branch.find_by!(name: "Toggle Branch")
      expect(branch.active).to be(true)

      patch admin_branch_path(branch), params: { branch: { active: "0" } }
      expect(branch.reload.active).to be(true)

      patch deactivate_admin_branch_path(branch), params: { reason: "Closed" }
      expect(branch.reload.active).to be(false)
      expect(Branch.active.for_business(business)).not_to include(branch)
    end

    it "assigns branch and area managers from the same business (management drives access scopes)" do
      manager = create(:user, business: business)
      branch  = create(:branch, business: business)
      patch admin_branch_path(branch), params: { branch: { branch_manager_id: manager.id, area_manager_id: manager.id } }
      expect(manager.reload.managed_branch_ids).to eq([ branch.id ])
      expect(manager.area_managed_branch_ids).to eq([ branch.id ])
      expect(manager.manages_branch?).to be(true)
    end

    it "deletes a never-used branch (with a reason; another branch stays active)" do
      create(:branch, business: business, name: "Main", active: true)
      branch = create(:branch, business: business)
      delete admin_branch_path(branch), params: { reason: "Created by mistake" }
      expect(Branch.exists?(branch.id)).to be(false)
      expect(flash[:notice]).to eq(I18n.t("flash.branch_deleted"))
    end

    # Was a known defect (the destroy result was ignored and "Branch removed."
    # shown); fixed by BUG-026. A branch with restricted history (here a POS
    # terminal, restrict_with_error) is not deleted, and the user is told why.
    it "refuses deletion blocked by restricted history and says so" do
      create(:branch, business: business, name: "Main", active: true)
      branch = create(:branch, business: business)
      branch.pos_terminals.create!(business: business, terminal_id: "T-#{SecureRandom.hex(3)}")
      delete admin_branch_path(branch), params: { reason: "Closing" }
      expect(Branch.exists?(branch.id)).to be(true)
      expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.has_history"))
      expect(flash[:notice]).to be_nil
    end

    it "branch changes are NOT audited (existing behaviour)" do
      expect {
        post admin_branches_path, params: { branch: { name: "Unaudited", branch_type: "sales" } }
      }.not_to change(AuditLog, :count)
    end
  end

  describe "business settings (/admin/settings)" do
    it "lets a manage_settings holder change timezone, locale and currency of their own business only" do
      sign_in owner
      patch admin_settings_path, params: { business: { timezone: "Africa/Cairo", default_locale: "ar", currency: "EGP",
                                                       owner_id: create(:user, business: business).id, name: "Renamed" } }
      expect(response).to redirect_to(admin_settings_path)
      business.reload
      expect([ business.timezone, business.default_locale, business.currency ]).to eq([ "Africa/Cairo", "ar", "EGP" ])
      expect(business.owner_id).to eq(owner.id) # owner_id is not a settings parameter
      expect(business.name).not_to eq("Renamed") # name is not a settings parameter
    end

    it "stores JSON-backed settings with their defaults and clamping" do
      sign_in owner
      expect(business.finance_overdue_days).to eq(3)
      patch admin_settings_path, params: { business: { finance_overdue_days: "500" } }
      expect(business.reload.finance_overdue_days).to eq(90) # clamped to 1..90
    end

    it "rejects an unknown timezone" do
      sign_in owner
      patch admin_settings_path, params: { business: { timezone: "Mars/Olympus" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(business.reload.timezone).to eq("Asia/Riyadh")
    end

    it "is refused without manage_settings" do
      sign_in api_user_with(business, :manage_branches)
      patch admin_settings_path, params: { business: { currency: "USD" } }
      expect(response).to redirect_to(root_path)
      expect(business.reload.currency).not_to eq("USD")
    end

    it "settings changes are NOT audited (existing behaviour)" do
      sign_in owner
      expect { patch admin_settings_path, params: { business: { currency: "USD" } } }.not_to change(AuditLog, :count)
    end
  end

  describe "locale endpoint (/locale)" do
    it "works without signing in and stores the locale in the session only" do
      patch set_locale_path, params: { locale: "ar" }, as: :json
      expect(response).to have_http_status(:ok)
      get new_user_session_path
      expect(response.body).to include('lang="ar"')
    end

    it "persists the preference on the account when signed in" do
      user = create(:user, business: business, preferred_locale: "en")
      sign_in user
      patch set_locale_path, params: { locale: "ar" }, as: :json
      expect(user.reload.preferred_locale).to eq("ar")
    end

    it "ignores an unsupported locale" do
      user = create(:user, business: business, preferred_locale: "en")
      sign_in user
      patch set_locale_path, params: { locale: "fr" }, as: :json
      expect(user.reload.preferred_locale).to eq("en")
    end
  end
end
