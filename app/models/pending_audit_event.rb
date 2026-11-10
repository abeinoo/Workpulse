# Durable record of an audit entry whose write failed (R3.1; plan §6.6, §6.8,
# §8, §18.2 G10, §19.13). Created only by Audit::DurableEntry and delivered only
# by Audit::PendingEventDelivery — never by log_audit / log_audit!, whose
# behaviour is unchanged (BUG-003).
#
# The row is the event's one notification: counters and failure details are
# updated in place, it is marked resolved (resolved_at + audit_log_id) once its
# AuditLog exists, and it is never deleted. Identity and payload columns never
# change after creation. payload holds the entry's changes and metadata and may
# contain financial or personal values: dashboards read OPERATIONAL_COLUMNS only
# (D30). entry_key is the entry's idempotency key: the AuditLog it resolves to
# is the one receipted under that key (DurableAuditReceipt, T-R31-11). The
# database enforces the same invariants with guard triggers (T-R31-14).
class PendingAuditEvent < ApplicationRecord
  class DeletionNotAllowedError < StandardError; end

  # Wait before each delivery retry; the original failed write is not a retry.
  # The first retry runs 1 minute after it, then 5 and 15 minutes after each
  # failure, then hourly (T-R31-6).
  RETRY_DELAYS   = [ 1.minute, 5.minutes, 15.minutes ].freeze
  HOURLY_RETRY   = 1.hour
  ESCALATE_AFTER = 3

  # A dispatched delivery job "claims" its event until its run time plus this
  # grace; the sweeper only enqueues due events whose claim has expired, so a
  # queue backlog does not pile up duplicate jobs, and a lost job is
  # re-enqueued once the claim lapses (T-R31-13).
  DISPATCH_GRACE = 10.minutes

  # Everything except payload: the only columns a dashboard or badge may load.
  OPERATIONAL_COLUMNS = %w[
    id entry_key business_id auditable_type auditable_id action attempted_at attempts consecutive_failures
    last_error last_error_details last_attempt_at next_attempt_at dispatch_claimed_until escalated_at
    resolved_at audit_log_id created_at updated_at
  ].freeze

  # business_id and actor_id are plain ids (foreign keys in the database): the
  # durable record never loads the account or its business, so it adds no
  # cross-domain reference beyond AuditLog's own (X-INFRA-AUDIT-ACTOR).
  belongs_to :audit_log, optional: true
  has_many :attempt_records, class_name: "PendingAuditEventAttempt", inverse_of: :pending_audit_event

  attr_readonly :entry_key, :business_id, :actor_id, :auditable_type, :auditable_id, :action, :payload, :attempted_at

  validates :entry_key, :business_id, :actor_id, :auditable_type, :auditable_id, :action, :attempted_at,
            presence: true
  validate  :unchanged_once_resolved, on: :update

  scope :unresolved,           -> { where(resolved_at: nil) }
  scope :resolved,             -> { where.not(resolved_at: nil) }
  scope :escalated_unresolved, -> { unresolved.where.not(escalated_at: nil) }
  scope :due,                  ->(now = Time.current) { unresolved.where(next_attempt_at: ..now) }
  scope :operational,          -> { select(OPERATIONAL_COLUMNS) }
  scope :dispatchable,         lambda { |now = Time.current|
    due(now).where(dispatch_claimed_until: nil).or(due(now).where(dispatch_claimed_until: ..now))
  }

  def self.retry_delay(retry_number)
    RETRY_DELAYS.fetch(retry_number - 1, HOURLY_RETRY)
  end

  def resolved?  = resolved_at.present?
  def escalated? = escalated_at.present?

  def status
    if resolved? then :resolved
    elsif escalated? then :escalated
    else :pending
    end
  end

  def due?(now = Time.current)
    !resolved? && next_attempt_at.present? && next_attempt_at <= now
  end

  # Called by Audit::PendingEventDelivery inside its locked transaction, in the
  # same savepoint as the AuditLog insert: the receipt's unique entry_key makes
  # a second AuditLog for this entry impossible.
  def mark_delivered!(audit_log, at:)
    DurableAuditReceipt.create!(entry_key: entry_key, audit_log: audit_log)
    resolve!(audit_log, at: at)
  end

  # The entry was already written under this entry_key (a first write whose
  # commit confirmation was lost): resolve to that AuditLog, write nothing.
  def adopt_receipt!(receipt, at:)
    resolve!(receipt.audit_log, at: at)
  end

  def record_failure!(error_class:, error_details:, at:)
    failures   = consecutive_failures + 1
    next_retry = at + self.class.retry_delay(failures + 1)
    update!(attempts: attempts + 1, consecutive_failures: failures, last_error: error_class,
            last_error_details: error_details, last_attempt_at: at, next_attempt_at: next_retry,
            dispatch_claimed_until: next_retry + DISPATCH_GRACE,
            escalated_at: escalated_at || (at if failures >= ESCALATE_AFTER))
  end

  def destroy = prevent_destruction
  def delete  = prevent_destruction

  private

  def resolve!(audit_log, at:)
    update!(resolved_at: at, audit_log: audit_log, last_attempt_at: at, next_attempt_at: nil,
            dispatch_claimed_until: nil, attempts: attempts + 1, consecutive_failures: 0)
  end

  def prevent_destruction
    raise DeletionNotAllowedError, "a pending audit event is never deleted (L34)"
  end

  def unchanged_once_resolved
    errors.add(:base, :resolved_event_unchanged) if resolved_at_in_database.present? && changed?
  end
end
