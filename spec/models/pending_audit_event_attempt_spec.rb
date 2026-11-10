require "rails_helper"

# R3.1 attempt log: append-only, automatic attempts only until R3.5 (T-R31-4).
RSpec.describe PendingAuditEventAttempt do
  let(:event) { create(:pending_audit_event) }
  let(:now)   { Time.current }

  def record_attempt(**attrs)
    described_class.create!({ pending_audit_event: event, business_id: event.business_id, kind: "automatic",
                              started_at: now, finished_at: now, result: "failed" }.merge(attrs))
  end

  it "is read-only once written and never deleted" do
    attempt = record_attempt

    expect { attempt.update!(result: "delivered") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { attempt.destroy }.to raise_error(PendingAuditEventAttempt::DeletionNotAllowedError)
    expect { attempt.delete }.to raise_error(PendingAuditEventAttempt::DeletionNotAllowedError)
    expect(event.attempt_records).to contain_exactly(attempt)
  end

  it "accepts automatic attempts only; manual attempts arrive with R3.5" do
    expect { record_attempt(kind: "manual") }.to raise_error(ActiveRecord::RecordInvalid)

    expect do
      described_class.new(pending_audit_event: event, business_id: event.business_id, kind: "manual",
                          started_at: now, finished_at: now, result: "failed").save!(validate: false)
    end.to raise_error(ActiveRecord::StatementInvalid, /kind_known/)
  end

  # The database error aborts the test transaction, so it is the last statement.
  it "keeps its result known and its times ordered" do
    expect { record_attempt(result: "skipped") }.to raise_error(ActiveRecord::RecordInvalid)
    expect do
      described_class.new(pending_audit_event: event, business_id: event.business_id, kind: "automatic",
                          started_at: now, finished_at: now - 1.second, result: "failed").save!(validate: false)
    end.to raise_error(ActiveRecord::StatementInvalid, /times_ordered/)
  end
end
