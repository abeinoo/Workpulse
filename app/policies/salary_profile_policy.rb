class SalaryProfilePolicy < ApplicationPolicy
  # Viewing (SEC-M2-5 / SEC-M2-7 decisions) — only ever the current profile:
  # the one in force today (SalaryProfile.effective_on, the rule payroll uses).
  # Superseded and not-yet-effective profiles stay stored but are never shown:
  # * one's own salary — with or without view_payroll and whatever the actor's
  #   own data scope;
  # * another employee's salary — view_payroll and the employee inside the
  #   configured view_payroll scope, or — none configured — the hierarchy default
  #   (EmployeeScope#for_permissions), never business-wide by default, as
  #   PayrollEntryPolicy.
  # Managing (SEC-M2-6): manage_salary_profiles, the employee inside the
  # manage_salary_profiles scope (same resolution), never one's own profile —
  # the owner included. Managing does not grant reading: creating a new profile
  # shows nothing existing, but editing in place shows the current amounts, so
  # it also needs the view rule. Only the current profile — the one in force
  # today — may be corrected in place, also while a later-dated change is
  # scheduled (and so holds the `active` flag); a scheduled profile is changed
  # by entering another profile.
  # History (view_salary_history): every stored profile of another employee —
  # previous, current and scheduled — on the employee page only, never through
  # the Scope (which stays current-only) or the API. The employee must be inside
  # both the view_payroll and the view_salary_history scope, so history never
  # reaches beyond the salaries the actor may already see; never one's own
  # history. Seeing history grants no editing.

  # Collection access is decided by the Scope; no instance rule is evaluated on
  # the class (AP-D1).
  def index? = true
  def show?  = profile? && Scope.new(user, SalaryProfile).resolve.exists?(id: record.id)

  # May the actor see this employee's salary at all? `record` is a profile of
  # the employee, persisted or SalaryProfile.new(user: employee).
  def view_salary? = profile? && (own? || self.class.viewable_employees(user).exists?(id: record.user_id))

  def create?  = profile? && can?(:manage_salary_profiles) && !own? &&
                 self.class.manageable_employees(user).exists?(id: record.user_id)
  def update?  = create? && record.effective? && view_salary?
  def destroy? = false

  def view_history? = profile? && !own? && self.class.history_viewable_employees(user).exists?(id: record.user_id)

  # Other employees whose salary the actor may view (never the actor).
  def self.viewable_employees(user)
    return User.none unless user.can?(:view_payroll)

    EmployeeScope.new(user).for_permissions(:view_payroll).where.not(id: user.id)
  end

  # Other employees whose full salary history the actor may view (never the actor).
  def self.history_viewable_employees(user)
    return User.none unless user.can?(:view_salary_history)

    viewable_employees(user).where(id: EmployeeScope.new(user).for_permissions(:view_salary_history).select(:id))
  end

  # Other employees whose salary profiles the actor may create or change.
  def self.manageable_employees(user)
    return User.none unless user.can?(:manage_salary_profiles)

    EmployeeScope.new(user).for_permissions(:manage_salary_profiles).where.not(id: user.id)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      others = SalaryProfilePolicy.viewable_employees(user)

      scope.where(user_id: others.select(:id)).or(scope.where(user_id: user.id))
           .effective_on(SalaryProfile.effective_date_for(user.business))
    end
  end

  private

  def profile? = record.is_a?(SalaryProfile)
  def own?     = record.user_id == user.id
end
