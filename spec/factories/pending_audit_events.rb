FactoryBot.define do
  factory :pending_audit_event do
    transient do
      actor { association :user }
    end

    entry_key       { SecureRandom.uuid }
    business_id     { actor.business_id }
    actor_id        { actor.id }
    auditable_type  { "User" }
    auditable_id    { actor.id }
    action          { "daily_paid_attendance_rejected" }
    payload         { { "changes" => { "base_salary" => [ "4000.0", "5500.0" ] }, "metadata" => { "reason" => "conflict" } } }
    attempted_at    { Time.current }
    next_attempt_at { attempted_at + PendingAuditEvent.retry_delay(1) }
  end
end
