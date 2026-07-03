class DepositVerificationPolicy < ApplicationPolicy
  def index? = can?(:view_deposit_verification)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.none
    end
  end
end
