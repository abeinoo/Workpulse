require "rails_helper"

RSpec.describe "Admin::PermissionRoles localization", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:role)    { create(:permission_role, :full_access, business: business) }

  # Every permission group/permission is rendered in the form regardless of
  # which permissions the role being edited actually holds — PERMISSION_GROUPS
  # and PERMISSION_DEPENDENCIES are global registries, not per-role data — so
  # editing any role exercises the full catalog, including the Laundry
  # section and every dependency badge.
  %w[en ar].each do |locale|
    context "locale=#{locale}" do
      before do
        owner.update!(preferred_locale: locale)
        sign_in owner
      end

      it "renders the edit form with no translation-missing content anywhere" do
        get edit_admin_permission_role_path(role)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to match(/[Tt]ranslation missing/)
      end

      it "renders the new form with no translation-missing content anywhere" do
        get new_admin_permission_role_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to match(/[Tt]ranslation missing/)
      end

      it "renders the expected dir attribute for the locale" do
        get edit_admin_permission_role_path(role)

        expected_dir = locale == "ar" ? 'dir="rtl"' : 'dir="ltr"'
        expect(response.body).to include(expected_dir)
      end
    end
  end

  context "in Arabic" do
    before do
      owner.update!(preferred_locale: "ar")
      sign_in owner
    end

    it "shows the Laundry group labels translated, not the raw group keys" do
      get edit_admin_permission_role_path(role)

      expect(response.body).to include(I18n.t("admin.permission_roles.groups.laundry_operations", locale: :ar))
      expect(response.body).to include(I18n.t("admin.permission_roles.groups.laundry_cost_reports", locale: :ar))
      expect(response.body).not_to include(">LAUNDRY OPERATIONS<")
      expect(response.body).not_to include(">LAUNDRY COST REPORTS<")
    end

    it "shows every Laundry permission name translated, not the raw permission key" do
      get edit_admin_permission_role_path(role)

      laundry_perms = PermissionRole::PERMISSION_GROUPS[:laundry_operations] +
                      PermissionRole::PERMISSION_GROUPS[:laundry_cost_reports]

      laundry_perms.each do |perm|
        expect(response.body).to include(I18n.t("admin.permission_roles.permissions.#{perm}", locale: :ar))
      end

      # Raw snake_case permission keys must never leak into the visible label text.
      expect(response.body).not_to match(%r{>\s*view_towel_balances\s*<})
      expect(response.body).not_to match(%r{>\s*confirm_towel_receipt\s*<})
    end

    it "no longer references the removed LaundryBatch permissions anywhere in the form" do
      get edit_admin_permission_role_path(role)

      %w[declare_dirty_towels manage_laundry_batches record_batch_consumption
         complete_laundry_batches dispatch_clean_towels].each do |perm|
        expect(response.body).not_to include(%(perm_#{perm}"))
      end
    end

    it "renders dependency badges using the translated permission label, not the English name" do
      get edit_admin_permission_role_path(role)

      # create_towel_transfers/confirm_towel_receipt/adjust_towel_balances all
      # depend on view_towel_balances.
      expect(response.body).to include(I18n.t("admin.permission_roles.form.requires", locale: :ar))
      expect(response.body).to include(I18n.t("admin.permission_roles.permissions.view_towel_balances", locale: :ar))
      expect(response.body).not_to include("Requires: View Towel Balances")

      # manage_laundry_cost_settings depends on view_laundry_cost_reports.
      expect(response.body).to include(I18n.t("admin.permission_roles.permissions.view_laundry_cost_reports", locale: :ar))
      expect(response.body).not_to include("Requires: View Laundry Cost Reports")
    end
  end

  context "in English" do
    before do
      owner.update!(preferred_locale: "en")
      sign_in owner
    end

    it "keeps every Laundry group and permission label fully in English" do
      get edit_admin_permission_role_path(role)

      expect(response.body).to include("Laundry Operations", "Laundry Cost Reports", "View Towel Balances",
                                       "Confirm Towel Receipt", "View Laundry Cost Reports")
    end
  end
end
