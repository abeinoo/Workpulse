# Business audit-failure dashboard (R3.1; T-R31-5): audit entries of the
# current business that could not be written yet, their retries and
# escalations. Operational columns only — the payload is never loaded (D30).
# Read-only: no Retry Now (R3.5).
class AuditFailuresController < ApplicationController
  before_action :authenticate_user!

  PER_PAGE = 25
  STATUSES = %w[open escalated resolved].freeze

  def index
    authorize PendingAuditEvent
    base = policy_scope(PendingAuditEvent)
    @counts = { open: base.unresolved.count, escalated: base.escalated_unresolved.count, resolved: base.resolved.count }

    @status = STATUSES.include?(params[:status]) ? params[:status] : "open"
    filtered = filtered_by_status(base)
    @total_pages = [ (filtered.count.to_f / PER_PAGE).ceil, 1 ].max
    @page        = [ [ params[:page].to_i, 1 ].max, @total_pages ].min
    @events      = filtered.operational.order(attempted_at: :desc, id: :desc)
                           .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def show
    @event = policy_scope(PendingAuditEvent).operational.find(params[:id])
    authorize @event
    @attempts = @event.attempt_records.order(:id)
  end

  private

  def filtered_by_status(base)
    case @status
    when "escalated" then base.escalated_unresolved
    when "resolved"  then base.resolved
    else base.unresolved
    end
  end
end
