require "rails_helper"

# R3.1 (attendance-requirements-and-cost-allocation plan, §6.6 / §18.2 G10):
# pins today's audit behaviour that the durable audit record is built around.
# Nothing here changes behaviour; each example characterizes code as it is.
RSpec.describe "Audit durability (characterization)" do
  include ActiveJob::TestHelper

  let(:host)      { Class.new { include AuditLoggable }.new }
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, business: business) }
  let(:auditable) { create(:user, business: business) }

  def audit(action: "characterized_action")
    host.log_audit(actor: actor, auditable: auditable, action: action, metadata: { note: "n" })
  end

  it "an audit entry written inside a transaction that is rolled back is gone with it" do
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        expect(audit).to be_persisted
        raise ActiveRecord::Rollback
      end
    end.not_to change(AuditLog, :count)
  end

  describe "a failed log_audit outside any transaction" do
    include_context "non-transactional database"

    let(:reports) { [] }
    let(:subscriber) do
      collected = reports
      Class.new { define_method(:report) { |error, **context| collected << [ error, context ] } }.new
    end

    around do |example|
      Rails.error.subscribe(subscriber)
      example.run
    ensure
      Rails.error.unsubscribe(subscriber)
    end

    it "returns nil and leaves no durable trace: no entry, nothing to retry, only one report" do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      fail_audit_writes!

      expect(audit).to be_nil
      expect(AuditLog.count).to eq(0)
      expect(enqueued_jobs).to be_empty
      expect(reports.size).to eq(1)
    end
  end

  describe "created_at of an entry written later" do
    it "log_audit stamps the time of the write, so an entry written later carries the later time" do
      travel_to(Time.zone.local(2026, 11, 8, 10, 0, 0)) { @log = audit }
      expect(@log.created_at).to eq(Time.zone.local(2026, 11, 8, 10, 0, 0))
    end

    it "an AuditLog created with an explicit created_at keeps it" do
      original = Time.zone.local(2026, 11, 1, 9, 30, 0)
      log = AuditLog.create!(actor: actor, business: business, auditable: auditable, action: "characterized_action",
                             changes_json: {}, metadata: {}, created_at: original)
      expect(log.reload.created_at).to eq(original)
    end
  end

  describe "enqueueing inside a transaction" do
    before { stub_const("AuditCharacterizationProbeJob", Class.new(ApplicationJob) { def perform; end }) }

    it "is sent immediately, even when the transaction then rolls back" do
      expect(ActiveJob::Base.enqueue_after_transaction_commit).to be(false)

      ActiveRecord::Base.transaction(requires_new: true) do
        AuditCharacterizationProbeJob.perform_later
        expect(enqueued_jobs.size).to eq(1)
        raise ActiveRecord::Rollback
      end

      expect(enqueued_jobs.size).to eq(1)
    end

    it "production writes jobs through a separate queue connection and does not defer enqueueing" do
      production = Rails.root.join("config/environments/production.rb").read
      expect(production).to include("config.solid_queue.connects_to = { database: { writing: :queue } }")
      expect(production).not_to include("enqueue_after_transaction_commit")
    end
  end
end
