module Payroll
  # Attendance & Payroll implementation of the Workforce Employee::ExportColumns
  # contract (registered in config/initializers/employee_export_columns.rb): the
  # salary columns of the Employee Data Export.
  #
  # The same visibility rule as the employee page's salary card: only the
  # salaries SalaryProfilePolicy::Scope shows the viewer — the profile in force
  # on the business day, of employees inside the viewer's view_payroll scope,
  # plus the viewer's own — never because the employee row is exportable
  # (SEC-M2-5). Every salary exported is recorded as a salary view, one
  # "view_salary" row per employee (Salary::ViewAudit, source employee_export),
  # exactly as when it is shown on a page.
  module EmployeeExportSalaryColumns
    module_function

    SOURCE = "employee_export".freeze

    def salary_values(viewer:, employee_ids:)
      return {} if employee_ids.empty?

      profiles = SalaryProfilePolicy::Scope.new(viewer, SalaryProfile).resolve
                                           .where(user_id: employee_ids)
                                           .where(user_id: User.where(business_id: viewer.business_id).select(:id))
                                           .to_a
      employees = User.where(id: profiles.map(&:user_id)).index_by(&:id)

      profiles.each_with_object({}) do |profile, values|
        Salary::ViewAudit.record(actor: viewer, employee: employees.fetch(profile.user_id),
                                 profiles: [ profile ], source: SOURCE)
        values[profile.user_id] = Employee::ExportColumns::SalaryValues.new(
          basic_salary: profile.base_amount,
          salary_type:  I18n.t("salary_profiles.salary_types.#{profile.salary_type}"),
          currency:     profile.currency
        )
      end
    end
  end
end
