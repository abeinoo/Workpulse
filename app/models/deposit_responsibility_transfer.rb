class DepositResponsibilityTransfer < ApplicationRecord
  include AuditLoggable

  belongs_to :daily_reconciliation
  belongs_to :from_user,    class_name: "User"
  belongs_to :to_user,      class_name: "User"
  belongs_to :cancelled_by, class_name: "User", optional: true

  scope :pending,   -> { where(accepted_at: nil, cancelled_at: nil) }
  scope :accepted,  -> { where.not(accepted_at: nil) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }

  delegate :business, :branch, to: :daily_reconciliation

  def pending?   = accepted_at.nil? && cancelled_at.nil?
  def accepted?  = accepted_at.present?
  def cancelled? = cancelled_at.present?
end
