FactoryBot.define do
  factory :attendance_adjustment do
    association :attendance_record
    field_name { "check_in_at" }
    old_value  { 2.hours.ago.iso8601 }
    new_value  { 1.hour.ago.iso8601 }
    reason     { "Manager correction after employee reported wrong time" }

    after(:build) do |adj|
      adj.adjusted_by ||= create(:user, business: adj.attendance_record.branch.business)
    end
  end
end
