require "rails_helper"
require "csv"

RSpec.describe Employee::Export::Exporter do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, name: "Riyadh Branch") }
  let(:branch_b) { create(:branch, business: business, name: "Jeddah Branch") }
  let!(:owner)   { create(:user, :owner, business: business, first_name: "Owner", last_name: "Person") }
  let(:department) { create(:department, business: business, name: "Operations") }
  let!(:job_title)  { create(:job_title, business: business, name: "Cashier") }

  let!(:emp_a) do
    create(:user, business: business, first_name: "محمد", last_name: "العتيبي",
                  identity_card_number: "1234567890", date_of_birth: Date.new(1990, 3, 15),
                  phone_number: "+966500000001", email: "mohammed@example.com", employee_code: "EMP-1",
                  job_title: "Cashier", department: department, hire_date: Date.new(2024, 1, 2),
                  employment_type: "full_time", address: "Street 1, \"Block\" 2\nRiyadh",
                  emergency_contact_name: "Ali", emergency_contact_phone: "0500000002",
                  emergency_contact_relationship: "Brother", admin_notes: "=HYPERLINK(\"http://x\")")
      .tap { assign(_1, branch_a) }
  end
  let!(:emp_b)    { create(:user, business: business, first_name: "Bella", last_name: "Bravo").tap { assign(_1, branch_b) } }
  let!(:inactive) { create(:user, business: business, first_name: "Ian", last_name: "Inactive", active: false) }
  let!(:outsider) { create(:user, business: create(:business), first_name: "Otto", last_name: "Outsider") }

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business, first_name: "Viewer").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def export(actor, fields, format: "csv", status: "all", **options)
    described_class.new(actor_id: actor.id, field_keys: fields, format: format, status: status, **options).call
  end

  def csv_rows(result)
    expect(result).to be_ok, "export refused: #{result.error}"
    data = result.record.data
    expect(data).to start_with("﻿")
    CSV.parse(data.delete_prefix("﻿"), headers: true)
  end

  def row_for(table, name) = table.find { _1[I18n.t("admin.users.export.fields.full_name")] == name }

  def export_audits = AuditLog.where(action: "export_employees")
  def salary_views  = AuditLog.where(action: "view_salary")

  let(:business_wide_exporter) do
    role_user(:view_employees, :export_employees, scopes: { "view_employees" => "business" })
  end

  describe "fields" do
    it "writes exactly the selected columns, in the selected order" do
      table = csv_rows(export(owner, %w[email full_name]))

      expect(table.headers).to eq([ I18n.t("admin.users.export.fields.email"), I18n.t("admin.users.export.fields.full_name") ])
      expect(row_for(table, "محمد العتيبي").fields).to eq([ "mohammed@example.com", "محمد العتيبي" ])
      expect(table.to_s).not_to include("1234567890", "EMP-1", "Cashier")
    end

    it "fills every catalogue field from the employee's stored data" do
      create(:salary_profile, user: emp_a, base_amount: 4321.5, currency: "SAR", salary_type: :monthly)
      create(:employee_insurance_profile, user: emp_a, business: business, insurance_number: "INS-9",
                                          insurance_start_date: Date.new(2024, 2, 1), employee_contribution_amount: 450)
      branch_a.update_column(:branch_manager_id, emp_b.id)

      table = csv_rows(export(owner, Employee::Export::FieldCatalog::FIELDS.map(&:key)))
      row = row_for(table, "محمد العتيبي").fields

      expect(row).to eq([
        "محمد العتيبي", "1234567890", "1990-03-15", "Street 1, \"Block\" 2\nRiyadh", "'+966500000001",
        "mohammed@example.com", "EMP-1", "Riyadh Branch", "Cashier", "Operations", "2024-01-02",
        I18n.t("admin.users.employment_types.full_time"), I18n.t("admin.users.active"), nil, "Bella Bravo",
        "4321.50", I18n.t("salary_profiles.salary_types.monthly"), "SAR",
        I18n.t("admin.users.export.insured.true"), "INS-9", "2024-02-01", nil, "450.00", "1250.00",
        "Ali", "0500000002", "Brother", "'=HYPERLINK(\"http://x\")"
      ])
    end

    it "leaves missing optional values empty" do
      inactive.update_columns(email: nil, phone_number: nil)
      fields = %w[full_name email phone_number date_of_birth department branch direct_manager hire_date
                  employment_type notes]
      table = csv_rows(export(owner, fields))

      expect(row_for(table, "Ian Inactive").fields).to eq([ "Ian Inactive" ] + Array.new(fields.size - 1))
    end

    it "names the area manager as the branch manager's own direct manager" do
      area = create(:user, business: business, first_name: "Area", last_name: "Boss")
      branch_a.update_columns(branch_manager_id: emp_a.id, area_manager_id: area.id)

      table = csv_rows(export(owner, %w[full_name direct_manager]))
      expect(row_for(table, "محمد العتيبي")[I18n.t("admin.users.export.fields.direct_manager")]).to eq("Area Boss")
    end
  end

  describe "refusals — the whole request, never a dropped field" do
    it "refuses a viewer without export_employees" do
      viewer = role_user(:view_employees, scopes: { "view_employees" => "business" })
      expect(export(viewer, %w[full_name]).error).to eq("not_authorized")
    end

    it "refuses unknown fields, including real columns outside the catalogue" do
      %w[encrypted_password reset_password_token password gender].each do |field|
        result = export(owner, [ "full_name", field ])
        expect(result).not_to be_ok
        expect(result.error).to eq("unauthorized_fields")
      end
    end

    it "refuses an empty or repeated field list, an unknown format and an unknown status" do
      expect(export(owner, []).error).to eq("no_fields")
      expect(export(owner, %w[email email]).error).to eq("duplicate_fields")
      expect(export(owner, %w[email], format: "pdf").error).to eq("invalid_format")
      expect(export(owner, %w[email], status: "everyone").error).to eq("invalid_status")
    end

    it "refuses National ID without export_employee_identity, and exports it with it" do
      expect(export(business_wide_exporter, %w[full_name national_id]).error).to eq("unauthorized_fields")

      viewer = role_user(:view_employees, :export_employees, :export_employee_identity,
                         scopes: { "view_employees" => "business" })
      table = csv_rows(export(viewer, %w[full_name national_id]))
      expect(row_for(table, "محمد العتيبي")[I18n.t("admin.users.export.fields.national_id")]).to eq("1234567890")
    end

    it "refuses salary fields without view_payroll" do
      %w[basic_salary salary_type salary_currency].each do |field|
        expect(export(business_wide_exporter, [ "full_name", field ]).error).to eq("unauthorized_fields")
      end
    end

    it "refuses insurance fields without an insurance permission, and the employer share without manage" do
      expect(export(business_wide_exporter, %w[social_insurance_number]).error).to eq("unauthorized_fields")

      viewer = role_user(:view_employees, :export_employees, :view_employee_insurance,
                         scopes: { "view_employees" => "business", "view_employee_insurance" => "business" })
      expect(export(viewer, %w[social_insurance_number])).to be_ok
      expect(export(viewer, %w[social_insurance_employer_contribution]).error).to eq("unauthorized_fields")
    end

    it "writes no audit entry and no salary view when refused" do
      create(:salary_profile, user: emp_a)
      export(business_wide_exporter, %w[full_name basic_salary])
      export(owner, %w[full_name unknown_field])

      expect(export_audits).to be_empty
      expect(salary_views).to be_empty
    end
  end

  describe "rows" do
    it "follows the status choice" do
      expect(csv_rows(export(owner, %w[full_name], status: "active")).map { _1[0] })
        .to contain_exactly("Owner Person", "محمد العتيبي", "Bella Bravo")
      expect(csv_rows(export(owner, %w[full_name], status: "inactive")).map { _1[0] }).to eq([ "Ian Inactive" ])
      expect(csv_rows(export(owner, %w[full_name], status: "all")).size).to eq(4)
    end

    it "never includes another business's employees" do
      expect(csv_rows(export(owner, %w[full_name])).map { _1[0] }).not_to include("Otto Outsider")
    end

    it "is limited to the Employees page's scope for the viewer" do
      manager = role_user(:view_employees, :export_employees)
      branch_a.update_column(:branch_manager_id, manager.id)

      names = csv_rows(export(manager, %w[full_name])).map { _1[0] }
      expect(names).to eq(UserPolicy::Scope.new(manager, User).resolve.order(:first_name, :last_name, :id).map(&:full_name))
      expect(names).to include("محمد العتيبي")
      expect(names).not_to include("Bella Bravo", "Owner Person", "Otto Outsider")
    end

    it "keeps the page order across batches" do
      table = csv_rows(export(owner, %w[full_name], batch_size: 2))
      expect(table.map { _1[0] })
        .to eq(User.where(business: business).order(:first_name, :last_name, :id).map(&:full_name))
    end
  end

  describe "salary columns (Employee::ExportColumns)" do
    let!(:salary_a) { create(:salary_profile, user: emp_a, base_amount: 1000) }
    let!(:salary_b) { create(:salary_profile, user: emp_b, base_amount: 2000) }

    it "fills salary only inside the viewer's view_payroll scope and audits each salary exported" do
      viewer = role_user(:view_employees, :export_employees, :view_payroll,
                         scopes: { "view_employees" => "business" })
      branch_a.update_column(:branch_manager_id, viewer.id)

      table  = csv_rows(export(viewer, %w[full_name basic_salary]))
      salary = I18n.t("admin.users.export.fields.basic_salary")
      expect(row_for(table, "محمد العتيبي")[salary]).to eq("1000.00")
      expect(row_for(table, "Bella Bravo")[salary]).to be_nil

      expect(salary_views.pluck(:auditable_id)).to eq([ emp_a.id ])
      expect(salary_views.first.metadata).to include("source" => "employee_export", "salary_profile_ids" => [ salary_a.id ])
      expect(export_audits.first.metadata["rows_without_salary"]).to eq(table.size - 1)
    end

    it "uses the salary in force on the business day, not a scheduled one" do
      create(:salary_profile, user: emp_a, base_amount: 9999, effective_from: 1.month.from_now.to_date)
      table = csv_rows(export(owner, %w[full_name basic_salary]))
      expect(row_for(table, "محمد العتيبي")[I18n.t("admin.users.export.fields.basic_salary")]).to eq("1000.00")
    end

    it "records no salary view when no salary column is selected" do
      export(owner, %w[full_name email])
      expect(salary_views).to be_empty
    end
  end

  describe "insurance columns" do
    it "fills insurance only inside the viewer's insurance scope" do
      create(:employee_insurance_profile, user: emp_a, business: business, insurance_number: "INS-A")
      create(:employee_insurance_profile, user: emp_b, business: business, insurance_number: "INS-B")
      viewer = role_user(:view_employees, :export_employees, :view_employee_insurance,
                         scopes: { "view_employees" => "business" })
      branch_a.update_column(:branch_manager_id, viewer.id)

      table  = csv_rows(export(viewer, %w[full_name social_insurance_number]))
      number = I18n.t("admin.users.export.fields.social_insurance_number")
      expect(row_for(table, "محمد العتيبي")[number]).to eq("INS-A")
      expect(row_for(table, "Bella Bravo")[number]).to be_nil
    end
  end

  describe "audit" do
    it "records one export entry with request facts only — never employee data" do
      result = export(owner, %w[full_name national_id email], status: "active")
      expect(result).to be_ok

      audit = export_audits.sole
      expect(audit.actor).to eq(owner)
      expect(audit.auditable).to eq(business)
      expect(audit.business_id).to eq(business.id)
      expect(audit.metadata).to eq("format" => "csv", "status" => "active",
                                   "fields" => %w[full_name national_id email], "row_count" => 3, "locale" => "en")
      stored = audit.attributes.to_json
      expect(stored).not_to include("محمد", "1234567890", "mohammed@example.com")
    end

    it "produces no file and keeps no salary view when the audit entry cannot be written" do
      create(:salary_profile, user: emp_a)
      allow(AuditLog).to receive(:create!).and_call_original
      allow(AuditLog).to receive(:create!).with(hash_including(action: "export_employees"))
                                          .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

      result = export(owner, %w[full_name basic_salary])
      expect(result).not_to be_ok
      expect(result.error).to eq("audit_failed")
      expect(result.record).to be_nil
      expect(export_audits).to be_empty
      expect(salary_views).to be_empty
    end

    it "changes no employee record" do
      expect { export(owner, Employee::Export::FieldCatalog::FIELDS.map(&:key)) }
        .not_to(change { User.order(:id).pluck(:updated_at) })
    end
  end

  describe "query budget" do
    let(:all_fields) { Employee::Export::FieldCatalog::FIELDS.map(&:key) }

    # Reads only: each exported salary also writes one view_salary audit row
    # (SEC-M2; savepoint, insert, release) — the only work that may grow with
    # the number of employees.
    def read_queries(fields)
      views_before = salary_views.count
      total = count_queries { export(owner, fields) }
      total - ((salary_views.count - views_before) * 3)
    end

    def add_employee(branch, salary:)
      emp = create(:user, business: business, department: create(:department, business: business))
      assign(emp, branch)
      create(:employee_insurance_profile, user: emp, business: business)
      create(:salary_profile, user: emp) if salary
    end

    it "does not grow with the number of employees (no N+1)" do
      add_employee(branch_a, salary: true)
      baseline = read_queries(all_fields)

      6.times { |i| add_employee(i.even? ? branch_a : branch_b, salary: true) }
      expect(read_queries(all_fields)).to eq(baseline)
    end

    it "does not query associated data for fields that were not selected" do
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { export(owner, %w[full_name email]) }

      expect(sql.grep(/salary_profiles|shift_assignments|employee_insurance_profiles|departments/)).to be_empty
    end
  end
end
