module Payroll
  # Attendance & Payroll implementation of the Workforce Employee::ProfilePanels
  # contract (registered in config/initializers/employee_profile_panels.rb): the
  # salary card of the employee page (SAL; module-boundaries.md §12.1 UI
  # composition).
  #
  # Was Admin::UsersController#load_salary plus the card in
  # app/views/admin/users/show.html.erb, unchanged: salary only under
  # SalaryProfilePolicy, never because the employee page itself is visible
  # (SEC-M2-5); the current profile; one salary-view audit when a profile is
  # shown (Salary::ViewAudit, source admin_employee_page). With view_salary_history
  # for the employee (SalaryProfilePolicy#view_history?) also every stored
  # profile, newest first, each labelled by its effective date — never by the
  # stored `active` flag — and audited once (source admin_employee_page_history).
  module EmployeeSalaryPanel
    module_function

    PARTIAL = "admin/salary_profiles/employee_panel".freeze

    # One row of the history table; status is :scheduled, :current or :previous.
    HistoryRow = Struct.new(:profile, :status)

    def salary_panel(viewer:, employee:)
      probe  = SalaryProfile.new(user_id: employee.id) # standalone: never built into employee.salary_profiles
      policy = SalaryProfilePolicy.new(viewer, probe)
      visible    = policy.view_salary?
      manageable = policy.create?
      # The salary in force today (the scope resolves the effective profile).
      profile = visible ? SalaryProfilePolicy::Scope.new(viewer, SalaryProfile).resolve.find_by(user: employee) : nil
      Salary::ViewAudit.record(actor: viewer, employee: employee, profiles: [ profile ], source: "admin_employee_page")
      return nil unless visible || manageable

      history = policy.view_history? ? history_rows(employee) : []
      Salary::ViewAudit.record(actor: viewer, employee: employee, profiles: history.map(&:profile),
                               source: "admin_employee_page_history")

      Employee::ProfilePanels::Panel.new(
        partial: PARTIAL,
        locals:  { employee: employee, salary_visible: visible, salary_manageable: manageable, profile: profile,
                   history: history }
      )
    end

    # The Salary Payment Hold section of the same page (Payroll::SalaryHoldPanel).
    def salary_hold_panel(viewer:, employee:)
      Payroll::SalaryHoldPanel.call(viewer: viewer, employee: employee)
    end

    # Every profile of the employee, newest first (the effective order). Status
    # from the effective date: after the business day → scheduled; the profile
    # in force today (SalaryProfile.effective_for, the payroll rule) → current;
    # the rest → previous.
    def history_rows(employee)
      today   = SalaryProfile.effective_date_for(employee.business)
      current = SalaryProfile.effective_for(employee, date: today)

      SalaryProfile.where(user_id: employee.id).order(SalaryProfile::EFFECTIVE_ORDER).map do |p|
        status = if p.effective_from > today then :scheduled
        elsif p == current then :current
        else :previous
        end
        HistoryRow.new(p, status)
      end
    end
  end
end
