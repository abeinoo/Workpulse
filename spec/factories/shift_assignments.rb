FactoryBot.define do
  factory :shift_assignment do
    transient do
      # Follows an explicitly given user, branch or shift, so an assignment never
      # mixes businesses (ShiftAssignment refuses that, BUG-031).
      business do
        given = %i[branch user shift].find { |name| __override_names__.include?(name) }
        given ? public_send(given).business : create(:business)
      end
    end

    user           { create(:user,          business: business) }
    shift          { create(:shift,         :fixed_time, business: business) }
    branch         { create(:branch,        business: business) }
    effective_from { 3.months.ago.to_date }
    effective_to   { nil }

    trait :temporary_coverage do
      assignment_kind { "temporary_coverage" }
      effective_from  { Date.current }
      effective_to    { Date.current + 1.day }
      reason          { "Covering another employee's absence" }
    end
  end
end
