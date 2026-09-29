class JobTitlePolicy < ApplicationPolicy
  # The job-title list feeds the employee form, so whoever manages employees
  # (or business settings) maintains it. Deactivation is the lifecycle — there
  # is no hard delete, since employees keep the name in users.job_title.
  def index?  = can?(:manage_employees) || can?(:manage_settings)
  def create? = index?
  def update? = index?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
