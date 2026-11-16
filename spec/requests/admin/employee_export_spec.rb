require "rails_helper"
require "csv"

# POST /admin/users/export — Employee Data Export. The controller only
# authorizes and hands over to Employee::Export::Exporter; these specs pin the
# HTTP contract and that a hand-crafted request cannot get past field rules.
RSpec.describe "Admin employee export", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:employee) do
    create(:user, business: business, first_name: "نورة", last_name: "السبيعي", email: "noura@example.com")
      .tap { create(:shift_assignment, business: business, user: _1, branch: branch, effective_from: 1.month.ago.to_date) }
  end
  let!(:salary) { create(:salary_profile, user: employee, base_amount: 7777) }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s),
                                              permission_scopes: { "view_employees" => "business", "view_payroll" => "business" })
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def post_export(fields:, file_format: "csv", employee_status: "all")
    post export_admin_users_path, params: { fields: fields, file_format: file_format, employee_status: employee_status }
  end

  def export_audits = AuditLog.where(action: "export_employees")

  context "without export_employees" do
    before { sign_in user_with(:view_employees) }

    it "refuses the request and records no export" do
      post_export(fields: %w[full_name])
      expect(response).to have_http_status(:redirect)
      expect(response.media_type).not_to eq("text/csv")
      expect(export_audits).to be_empty
    end

    it "shows no Export button" do
      get admin_users_path
      expect(response.body).not_to include('data-testid="export-employees"')
    end
  end

  context "with export_employees only" do
    before { sign_in user_with(:view_employees, :export_employees) }

    it "downloads a CSV attachment that is never cached" do
      post_export(fields: %w[full_name email])

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.headers["Content-Disposition"]).to match(/attachment; filename="employees_\d{8}_\d{4}\.csv"/)
      expect(response.headers["Cache-Control"]).to include("no-store")
      table = CSV.parse(response.body.force_encoding("UTF-8").delete_prefix("﻿"), headers: true)
      expect(table.map(&:fields)).to include([ "نورة السبيعي", "noura@example.com" ])
      expect(export_audits.count).to eq(1)
    end

    it "downloads an Excel workbook" do
      post_export(fields: %w[full_name], file_format: "xlsx")
      expect(response.media_type).to eq(Employee::Export::XlsxRenderer::CONTENT_TYPE)
      expect(response.headers["Content-Disposition"]).to include(".xlsx")
    end

    it "refuses a hand-crafted request for National ID or salary — nothing exported, nothing audited" do
      [ %w[full_name national_id], %w[full_name basic_salary], %w[full_name encrypted_password] ].each do |fields|
        post_export(fields: fields)
        expect(response).to redirect_to(admin_users_path)
        expect(flash[:alert]).to eq(I18n.t("admin.users.export.errors.unauthorized_fields"))
      end
      expect(export_audits).to be_empty
      expect(AuditLog.where(action: "view_salary")).to be_empty
    end

    it "refuses fields sent as anything but a list" do
      post export_admin_users_path, params: { fields: { "0" => "full_name" }, file_format: "csv", employee_status: "all" }
      expect(flash[:alert]).to eq(I18n.t("admin.users.export.errors.no_fields"))
      expect(export_audits).to be_empty
    end

    it "offers only the permitted fields in the dialog" do
      get admin_users_path
      expect(response.body).to include('data-testid="export-employees"', 'data-testid="export-field-full_name"')
      expect(response.body).not_to include('data-testid="export-field-national_id"', 'data-testid="export-field-basic_salary"')
    end
  end

  context "with National ID and salary rights" do
    before { sign_in user_with(:view_employees, :export_employees, :export_employee_identity, :view_payroll) }

    it "offers and exports them" do
      get admin_users_path
      expect(response.body).to include('data-testid="export-field-national_id"', 'data-testid="export-field-basic_salary"')

      post_export(fields: %w[full_name national_id basic_salary])
      expect(response).to have_http_status(:ok)
      expect(response.body.force_encoding("UTF-8")).to include(employee.identity_card_number, "7777.00")
    end
  end

  it "keeps the dialog in Arabic for an Arabic user" do
    viewer = user_with(:view_employees, :export_employees)
    viewer.update_column(:preferred_locale, "ar")
    sign_in viewer
    get admin_users_path
    expect(response.body).to include(I18n.t("admin.users.export.title", locale: :ar),
                                     I18n.t("admin.users.export.fields.full_name", locale: :ar))
  end
end
