class PaymentMethodPolicy < ApplicationPolicy
  # Readable by anyone who can configure finances (they need it for pickers);
  # write actions require the dedicated manage_payment_methods permission.
  def index?   = can?(:manage_payment_methods) || can?(:view_finance_dashboard) || owner?
  def show?    = index?
  def create?  = can?(:manage_payment_methods)
  def update?  = can?(:manage_payment_methods)
  def destroy? = can?(:manage_payment_methods)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
