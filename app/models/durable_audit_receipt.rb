# Idempotency receipt of an audit entry written through the opt-in durable API
# (R3.1; plan §19.13 T-R31-11). Inserted in the same transaction as its
# AuditLog, under the entry_key chosen before the first write: entry_key is
# unique in the database, so an entry can be written at most once — a retry
# after a commit whose confirmation was lost finds the receipt instead of
# writing a second AuditLog. AuditLog itself is unchanged. Append-only (model
# and database trigger).
class DurableAuditReceipt < ApplicationRecord
  class DeletionNotAllowedError < StandardError; end

  belongs_to :audit_log

  validates :entry_key, presence: true

  def readonly? = persisted? || super

  def destroy = prevent_destruction
  def delete  = prevent_destruction

  private

  def prevent_destruction
    raise DeletionNotAllowedError, "a durable audit receipt is never deleted"
  end
end
