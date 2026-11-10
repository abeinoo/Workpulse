require "rails_helper"

# R3.1 opt-in durable audit write (plan §6.6, §19.13 T-R31-8, D28, D29).
RSpec.describe Audit::DurableEntry do
  include ActiveJob::TestHelper

  let(:business)  { create(:business) }
  let(:actor)     { create(:user, business: business) }
  let(:auditable) { create(:user, business: business) }
  let(:changes)   { { "base_salary" => [ BigDecimal("4000.5"), BigDecimal("5500") ] } }
  let(:metadata)  { { "reason" => "SECRET-REASON", "conflicting_date" => "2026-11-03" } }

  let(:reports) { [] }
  let(:subscriber) do
    collected = reports
    Class.new do
      define_method(:report) { |error, handled:, severity:, context:, source:| collected << { error: error, context: context, source: source } }
    end.new
  end

  around do |example|
    Rails.error.subscribe(subscriber)
    example.run
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  def record_entry
    described_class.record(actor: actor, auditable: auditable, action: :daily_paid_attendance_rejected,
                           changes: changes, metadata: metadata)
  end

  context "when the audit write succeeds" do
    it "writes the AuditLog through log_audit! and keeps nothing pending" do
      result = nil
      expect { result = record_entry }.to change(AuditLog, :count).by(1)
      expect(PendingAuditEvent.count).to eq(0)

      expect(result).to be_ok
      expect(result).not_to be_pending
      expect(result.record).to have_attributes(actor_id: actor.id, business_id: business.id, auditable: auditable,
                                               action: "daily_paid_attendance_rejected")
      expect(DurableAuditReceipt.sole.audit_log_id).to eq(result.record.id)
      expect(enqueued_jobs).to be_empty
    end
  end

  context "when the audit write fails" do
    before { fail_audit_writes! }

    it "calls log_audit! exactly once" do
      expect_any_instance_of(described_class).to receive(:log_audit!).once.and_call_original # rubocop:disable RSpec/AnyInstance
      record_entry
    end

    it "keeps the entry in a pending event with the original attempt time, and schedules the first retry" do
      attempted_at = Time.zone.local(2026, 11, 8, 9, 15, 0)
      result = travel_to(attempted_at) { record_entry }

      expect(result).to be_ok
      expect(result).to be_pending
      expect(AuditLog.count).to eq(0)
      expect(result.record.reload).to have_attributes(
        business_id: business.id, actor_id: actor.id, auditable_type: "User", auditable_id: auditable.id,
        action: "daily_paid_attendance_rejected", attempted_at: attempted_at, attempts: 0, consecutive_failures: 0,
        next_attempt_at: attempted_at + 1.minute, last_error: "ActiveRecord::InvalidForeignKey",
        resolved_at: nil, escalated_at: nil,
        dispatch_claimed_until: attempted_at + 1.minute + PendingAuditEvent::DISPATCH_GRACE
      )
      expect(result.record.entry_key).to be_present
      expect(DurableAuditReceipt.count).to eq(0)
      expect(result.record.payload).to eq("changes" => { "base_salary" => [ "4000.5", "5500.0" ] }, "metadata" => metadata)
      expect(result.record.last_error_details).to include("sqlstate" => "23503", "constraint" => a_string_matching(/fk_/))
    end

    it "enqueues the delivery job for the first retry" do
      result = record_entry

      expect(Audit::PendingEventDeliveryJob).to have_been_enqueued.with(result.record.id)
        .at(result.record.next_attempt_at).on_queue("background")
    end

    it "reports the failed write once, through the unchanged global report, without values" do
      record_entry

      expect(reports.size).to eq(1)
      expect(reports.first[:source]).to eq("audit_log.work_pulse")
      expect(reports.first[:context].to_s).not_to include("SECRET-REASON")
    end

    it "keeps the pending event when the enqueue fails, and releases its claim so the sweeper delivers it" do
      allow(Audit::PendingEventDeliveryJob).to receive(:set).and_raise(ActiveRecord::ConnectionNotEstablished, "queue down")

      result = record_entry

      expect(result).to be_ok
      expect(result).to be_pending
      expect(PendingAuditEvent.find(result.record.id).dispatch_claimed_until).to be_nil
      expect(reports.map { |r| r[:source] }).to eq(%w[audit_log.work_pulse pending_audit_event.work_pulse])
    end

    # L2: three separate boundaries — only a failed durable record is "lost".
    it "reports persistence accurately when the enqueue fails and logging that failure fails too" do
      allow(Audit::PendingEventDeliveryJob).to receive(:set).and_raise(ActiveRecord::ConnectionNotEstablished, "queue down")
      logged = []
      allow(Rails.logger).to receive(:error).and_wrap_original do |original, message|
        raise IOError, "log sink down" if message.include?("enqueue failed")

        logged << message
        original.call(message)
      end

      result = nil
      expect { result = record_entry }.not_to raise_error

      expect(result).to be_ok
      expect(result).to be_pending
      expect(result.error).to be_nil
      expect(PendingAuditEvent.count).to eq(1)
      expect(logged.join).not_to include("full entry", "SECRET-REASON")
    end

    # L1: the attempt time and key are fixed before anything can fail, and the
    # transaction check never checks out a connection.
    it "keeps the original attempt time when the database is unavailable at first and recovers" do
      [ actor, auditable ].each(&:reload)
      calls = 0
      allow(ActiveRecord::Base).to receive(:with_connection).and_wrap_original do |original, *args, **kwargs, &block|
        calls += 1
        raise ActiveRecord::ConnectionNotEstablished, "checkout failed" if calls == 1

        original.call(*args, **kwargs, &block)
      end
      attempted_at = Time.zone.local(2026, 11, 8, 9, 15, 0)

      result = travel_to(attempted_at) { record_entry }

      expect(result).to be_ok
      expect(result).to be_pending
      expect(result.record.reload).to have_attributes(attempted_at: attempted_at, next_attempt_at: attempted_at + 1.minute,
                                                      last_error: "ActiveRecord::ConnectionNotEstablished")
    end

    it "checks for an open transaction without needing a connection, so that check cannot fail" do
      guard = described_class.new
      allow(ActiveRecord::Base).to receive(:with_connection).and_raise(ActiveRecord::ConnectionNotEstablished, "down")
      allow(ActiveRecord::Base.connection_pool).to receive(:checkout).and_raise(ActiveRecord::ConnectionNotEstablished, "down")

      expect { guard.send(:ensure_outside_transaction!) }.not_to raise_error
    end

    context "and the durable record cannot be written either" do
      before { allow(PendingAuditEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "durable down") }

      it "logs the full entry, values included, as the last-resort recovery source (D28) — never to the reporter" do
        logged = []
        allow(Rails.logger).to receive(:error).and_wrap_original { |m, message| logged << message; m.call(message) }

        result = record_entry

        expect(result).not_to be_ok
        expect(result.error).to be_a(ActiveRecord::StatementInvalid)
        last_resort = logged.find { |line| line.include?("Durable audit record could not be written") }
        expect(last_resort).to include("SECRET-REASON", "4000.5", "daily_paid_attendance_rejected", "entry_key")
        report = reports.find { |r| r[:source] == "pending_audit_event.work_pulse" }
        expect(report[:error]).to be_a(Audit::SafeReporting::SanitizedError)
        expect(report[:context]).to include(actor_id: actor.id, change_keys: [ "base_salary" ],
                                            metadata_keys: %w[reason conflicting_date],
                                            audit_error_class: "ActiveRecord::InvalidForeignKey",
                                            durable_record_error_class: "ActiveRecord::StatementInvalid")
        expect(reports.map { |r| "#{r[:context]} #{r[:error].message}" }.join).not_to include("SECRET-REASON", "4000.5")
        expect(PendingAuditEvent.count).to eq(0)
        expect(enqueued_jobs).to be_empty
      end
    end
  end

  it "refuses to run inside an open transaction, writing nothing" do
    fail_audit_writes!

    expect do
      ActiveRecord::Base.transaction { record_entry }
    end.to raise_error(described_class::CalledInsideTransaction)
    expect(PendingAuditEvent.count).to eq(0)
  end

  describe "after the caller's transaction has rolled back (production commit path)" do
    include_context "non-transactional database"

    it "commits the pending event outside it and enqueues only after that commit" do
      fail_audit_writes!
      open_at_enqueue = nil
      allow(Audit::PendingEventDeliveryJob).to receive(:set).and_wrap_original do |original, **options|
        open_at_enqueue = ActiveRecord::Base.with_connection(&:transaction_open?)
        original.call(**options)
      end

      [ actor, auditable ].each(&:reload) # committed before the caller's transaction
      ActiveRecord::Base.transaction do
        auditable.update!(first_name: "Rejected")
        raise ActiveRecord::Rollback
      end
      result = record_entry

      expect(auditable.reload.first_name).not_to eq("Rejected")
      expect(result).to be_pending
      expect(PendingAuditEvent.count).to eq(1)
      expect(open_at_enqueue).to be(false)
    end
  end
end
