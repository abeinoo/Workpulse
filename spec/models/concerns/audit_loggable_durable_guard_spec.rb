require "rails_helper"

# R3.1 regression guard (BUG-003 boundary): the durable record is opt-in. A
# failed write through the existing log_audit / log_audit! never creates a
# PendingAuditEvent or enqueues a delivery, inside or outside a transaction.
RSpec.describe "AuditLoggable never writes the durable record" do
  include ActiveJob::TestHelper

  let(:host)      { Class.new { include AuditLoggable }.new }
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, business: business) }
  let(:auditable) { create(:user, business: business) }

  before { fail_audit_writes! }

  def audit  = host.log_audit(actor: actor, auditable: auditable, action: "existing_caller", metadata: { note: "n" })
  def audit! = host.log_audit!(actor: actor, auditable: auditable, action: "existing_caller", metadata: { note: "n" })

  it "log_audit: still returns nil and keeps nothing" do
    expect(audit).to be_nil
    expect(PendingAuditEvent.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end

  it "log_audit inside a caller transaction: keeps nothing" do
    ActiveRecord::Base.transaction { audit }
    expect(PendingAuditEvent.count).to eq(0)
  end

  it "log_audit!: still raises AuditWriteFailed and keeps nothing" do
    expect { audit! }.to raise_error(AuditLoggable::AuditWriteFailed)
    expect(PendingAuditEvent.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end

  it "a successful log_audit writes the AuditLog exactly as before: no receipt, no pending event, same columns" do
    RSpec::Mocks.space.proxy_for(AuditLog).reset

    expect(audit).to be_persisted
    expect(DurableAuditReceipt.count).to eq(0)
    expect(PendingAuditEvent.count).to eq(0)
    expect(AuditLog.column_names).to match_array(
      %w[id actor_id business_id auditable_type auditable_id action changes_json metadata created_at]
    )
  end

  it "AuditLoggable does not name the durable record or its services" do
    source = Rails.root.join("app/models/concerns/audit_loggable.rb").read
    expect(source).not_to match(/PendingAuditEvent|DurableAuditReceipt|Audit::|DurableEntry/)
  end
end
