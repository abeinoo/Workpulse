require "rails_helper"

RSpec.describe "Admin::ShiftRuleProfiles", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:employee) { create(:user, business: business) }
  let!(:profile) { create(:shift_rule_profile, business: business) }

  # ── Index ──────────────────────────────────────────────────────────────────

  describe "GET /admin/shift_rule_profiles" do
    context "as owner" do
      before { sign_in owner }

      it "returns 200" do
        get admin_shift_rule_profiles_path
        expect(response).to have_http_status(:ok)
      end

      it "shows profile names" do
        get admin_shift_rule_profiles_path
        expect(response.body).to include(profile.name)
      end
    end

    context "as plain employee" do
      before { sign_in employee }

      it "redirects (access denied)" do
        get admin_shift_rule_profiles_path
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ── Show ───────────────────────────────────────────────────────────────────

  describe "GET /admin/shift_rule_profiles/:id" do
    before { sign_in owner }

    it "returns 200" do
      get admin_shift_rule_profile_path(profile)
      expect(response).to have_http_status(:ok)
    end
  end

  # ── Create ─────────────────────────────────────────────────────────────────

  describe "POST /admin/shift_rule_profiles" do
    before { sign_in owner }

    let(:valid_params) do
      {
        shift_rule_profile: {
          name:                     "Ramadan",
          expected_work_hours:      "6.0",
          late_grace_minutes:       "10",
          early_leave_grace_minutes: "10",
          overtime_enabled:         "1",
          active:                   "1"
        }
      }
    end

    it "creates a profile and redirects to show" do
      expect {
        post admin_shift_rule_profiles_path, params: valid_params
      }.to change(ShiftRuleProfile, :count).by(1)
      expect(response).to redirect_to(admin_shift_rule_profile_path(ShiftRuleProfile.last))
    end

    it "renders new on invalid params" do
      post admin_shift_rule_profiles_path, params: { shift_rule_profile: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── Update ─────────────────────────────────────────────────────────────────

  describe "PATCH /admin/shift_rule_profiles/:id" do
    before { sign_in owner }

    it "updates and redirects" do
      patch admin_shift_rule_profile_path(profile),
            params: { shift_rule_profile: { name: "Updated", overtime_enabled: "1" } }
      expect(response).to redirect_to(admin_shift_rule_profile_path(profile))
      expect(profile.reload.name).to eq("Updated")
    end

    it "renders edit on invalid params" do
      patch admin_shift_rule_profile_path(profile),
            params: { shift_rule_profile: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── Destroy ────────────────────────────────────────────────────────────────

  describe "DELETE /admin/shift_rule_profiles/:id" do
    before { sign_in owner }

    it "deletes profile when not in use and redirects" do
      expect {
        delete admin_shift_rule_profile_path(profile)
      }.to change(ShiftRuleProfile, :count).by(-1)
      expect(response).to redirect_to(admin_shift_rule_profiles_path)
    end

    it "refuses deletion when profile is linked to an assignment" do
      shift      = create(:shift, :fixed_time, business: business)
      employee_u = create(:user, business: business)
      create(:shift_assignment, user: employee_u, shift: shift, rule_profile: profile,
             effective_from: Date.current)

      expect {
        delete admin_shift_rule_profile_path(profile)
      }.not_to change(ShiftRuleProfile, :count)
      expect(response).to redirect_to(admin_shift_rule_profiles_path)
    end
  end
end
