# Business audit-failure dashboard (R3.1; plan §6.8, §18.2 G2, D30, D32).
# monitor_audit_failures, business level; owners have it implicitly. Every
# query is filtered by business_id in the database: another business's event
# is not found, never hidden by the UI. No retry here — Retry Now is the
# platform operator's (R3.5).
class PendingAuditEventPolicy < ApplicationPolicy
  def index? = can?(:monitor_audit_failures)
  def show?  = index? && record.business_id == user.business_id

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:monitor_audit_failures)

      scope.where(business_id: user.business_id)
    end
  end
end
