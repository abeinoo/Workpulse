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
  # it also needs the view rule. Only the current profile, and only while it is
  # still the latest entered (`active`), may be corrected in place; a scheduled
  # change is made by entering another profile.

  # Collection access is decided by the Scope; no instance rule is evaluated on
  # the class (AP-D1).
  def index? = true
  def show?  = profile? && Scope.new(user, SalaryProfile).resolve.exists?(id: record.id)

  # May the actor see this employee's salary at all? `record` is a profile of
  # the employee, persisted or SalaryProfile.new(user: employee).
  def view_salary? = profile? && (own? || self.class.viewable_employees(user).exists?(id: record.user_id))

  def create?  = profile? && can?(:manage_salary_profiles) && !own? &&
                 self.class.manageable_employees(user).exists?(id: record.user_id)
  def update?  = create? && record.active? && record.effective? && view_salary?
  def destroy? = false

  # Other employees whose salary the actor may view (never the actor).
  def self.viewable_employees(user)
    return User.none unless user.can?(:view_payroll)

    EmployeeScope.new(user).for_permissions(:view_payroll).where.not(id: user.id)
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
