# Append-only log of delivery attempts for a PendingAuditEvent (R3.1; L34,
# §18.2 G10). Written by Audit::PendingEventDelivery in its own transaction
# after the delivery transaction ends (T-R31-1). Never updated or deleted.
# R3.1 records automatic attempts only; R3.5 adds manual attempts and their
# operator (T-R31-4).
class PendingAuditEventAttempt < ApplicationRecord
  class DeletionNotAllowedError < StandardError; end

  KINDS   = %w[automatic].freeze
  RESULTS = %w[delivered failed].freeze

  belongs_to :pending_audit_event, inverse_of: :attempt_records

  validates :kind,   inclusion: { in: KINDS }
  validates :result, inclusion: { in: RESULTS }
  validates :business_id, :started_at, :finished_at, presence: true

  def readonly? = persisted? || super

  def destroy = prevent_destruction
  def delete  = prevent_destruction

  private

  def prevent_destruction
    raise DeletionNotAllowedError, "the audit attempt log is append-only (L34)"
  end
end
