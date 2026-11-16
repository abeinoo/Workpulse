require "rails_helper"

# Browser coverage for the Employee Data Export dialog on the Employees page:
# opening it, field search, select / deselect all, the selected-fields counter
# and the Export button that stays disabled until a field is chosen — in English
# (LTR) and Arabic (RTL). The download itself is covered by the request spec.
RSpec.describe "Employee export dialog", type: :system do
  let(:business) { create(:business) }

  def viewer(locale)
    role = business.permission_roles.create!(name: "Exporter #{locale}", permissions: %w[view_employees export_employees],
                                              permission_scopes: { "view_employees" => "business" })
    create(:user, business: business, preferred_locale: locale).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def checked_count = all("input[name='fields[]']:checked", visible: :all).size

  %w[en ar].each do |locale|
    it "selects, searches and counts fields (#{locale})" do
      user = viewer(locale)
      offered = Employee::Export::FieldCatalog.permitted_fields(user).size
      sign_in user
      visit admin_users_path

      find("[data-testid='export-employees']").click
      within("#employee-export-dialog") do
        title = I18n.t("admin.users.export.title", locale: locale)
        expect(page).to have_css("h2", text: title)
        expect(find("[data-testid='export-submit']")).to be_disabled
        expect(page).to have_css("[data-testid='export-selected-count']", text: "0")

        click_button I18n.t("admin.users.export.select_all", locale: locale)
        expect(page).to have_css("[data-testid='export-selected-count']", text: offered.to_s)
        expect(checked_count).to eq(offered)
        expect(find("[data-testid='export-submit']")).not_to be_disabled

        click_button I18n.t("admin.users.export.deselect_all", locale: locale)
        expect(page).to have_css("[data-testid='export-selected-count']", text: "0")
        expect(find("[data-testid='export-submit']")).to be_disabled

        email_label = I18n.t("admin.users.export.fields.email", locale: locale)
        find("input[type='search']").fill_in(with: email_label)
        expect(page).to have_css("[data-testid='export-field-email']", visible: true)
        expect(page).to have_no_css("[data-testid='export-field-full_name']", visible: true)

        click_button I18n.t("admin.users.export.select_all", locale: locale)
        expect(page).to have_css("[data-testid='export-selected-count']", text: "1")
        expect(find("[data-testid='export-field-email']", visible: :all)).to be_checked
      end
    end
  end
end
