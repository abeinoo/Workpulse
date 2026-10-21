module Payroll
  # Attendance & Payroll implementation of the Workforce Employee::ProfilePanels
  # contract (registered in config/initializers/employee_profile_panels.rb): the
  # salary card of the employee page (SAL; module-boundaries.md §12.1 UI
  # composition).
  #
  # Was Admin::UsersController#load_salary plus the card in
  # app/views/admin/users/show.html.erb, unchanged: salary only under
  # SalaryProfilePolicy, never because the employee page itself is visible
  # (SEC-M2-5); the current profile only (no history); one salary-view audit when
  # a profile is shown (Salary::ViewAudit, source admin_employee_page).
  module EmployeeSalaryPanel
    module_function

    PARTIAL = "admin/salary_profiles/employee_panel".freeze

    def salary_panel(viewer:, employee:)
      probe  = SalaryProfile.new(user_id: employee.id) # standalone: never built into employee.salary_profiles
      policy = SalaryProfilePolicy.new(viewer, probe)
      visible    = policy.view_salary?
      manageable = policy.create?
      # The salary in force today (the scope resolves the effective profile).
      profile = visible ? SalaryProfilePolicy::Scope.new(viewer, SalaryProfile).resolve.find_by(user: employee) : nil
      Salary::ViewAudit.record(actor: viewer, employee: employee, profiles: [ profile ], source: "admin_employee_page")
      return nil unless visible || manageable

      Employee::ProfilePanels::Panel.new(
        partial: PARTIAL,
        locals:  { employee: employee, salary_visible: visible, salary_manageable: manageable, profile: profile }
      )
    end
  end
end
