class DepositResponsibilityTransfer < ApplicationRecord
  include AuditLoggable

  # A request to move a DR's deposit responsibility (TillSession#depositor)
  # from from_user to to_user. Requested at Day Close (TillHandoverCreator) or
  # later by a manager (Finance::DepositResponsibilityTransferRequester).
  #
  #   pending ─┬─ accepted  → depositor becomes the accepter
  #            ├─ rejected  → recipient declined; from_user stays depositor
  #            └─ cancelled → withdrawn; from_user stays depositor
  #
  # State is derived from the timestamps, never stored as a flag. At most one
  # pending transfer per DR (idx_drt_one_pending_per_dr).
  REJECTION_REASON_MAX_LENGTH = 500

  belongs_to :daily_reconciliation
  belongs_to :from_user,    class_name: "User"
  belongs_to :to_user,      class_name: "User"
  belongs_to :initiated_by, class_name: "User", optional: true
  belongs_to :accepted_by,  class_name: "User", optional: true
  belongs_to :rejected_by,  class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true

  scope :pending,   -> { where(accepted_at: nil, cancelled_at: nil, rejected_at: nil) }
  scope :accepted,  -> { where.not(accepted_at: nil) }
  scope :rejected,  -> { where.not(rejected_at: nil) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }

  delegate :business, :branch, to: :daily_reconciliation

  def pending?   = accepted_at.nil? && cancelled_at.nil? && rejected_at.nil?
  def accepted?  = accepted_at.present?
  def rejected?  = rejected_at.present?
  def cancelled? = cancelled_at.present?

  # Who asked for the transfer — a manager for DR-page requests, otherwise
  # the depositor handing over (Day Close and rows predating initiated_by).
  def requester = initiated_by || from_user

  # Who actually accepted — the recipient, or the business owner under the
  # owner-may-accept rule. Rows predating accepted_by were always to_user
  # unless the owner took over, which is only recorded in the AuditLog.
  def acceptor = accepted_by || to_user
end
