FactoryBot.define do
  factory :attendance_record do
    transient do
      business { create(:business) }
      shift    { nil }
    end

    user                { create(:user,   business: business) }
    branch              { create(:branch, business: business) }
    date                { Date.current }
    work_date           { Date.current }
    check_in_at         { 2.hours.ago.change(sec: 0) }
    status              { :incomplete }
    late_minutes        { 0 }
    early_leave_minutes { 0 }
    worked_minutes      { nil }

    # Builds the shift_assignment from the same user/branch, creating one if not provided.
    after(:build) do |record, evaluator|
      next unless record.shift_assignment.nil?

      the_shift = evaluator.shift ||
        create(:shift, :fixed_time, business: record.branch.business)
      record.shift_assignment = create(
        :shift_assignment,
        user:           record.user,
        branch:         record.branch,
        shift:          the_shift,
        effective_from: 1.year.ago.to_date
      )
    end

    trait :checked_out do
      check_out_at        { Time.current.change(hour: 17, min: 0, sec: 0) }
      worked_minutes      { 480 }
      early_leave_minutes { 0 }
      status              { :present }
    end

    trait :late do
      check_in_at  { Time.current.change(hour: 10, min: 0, sec: 0) }
      late_minutes { 60 }
      status       { :late }
    end

    trait :early_leave do
      check_in_at         { Time.current.change(hour: 9, min: 0, sec: 0) }
      check_out_at        { Time.current.change(hour: 15, min: 0, sec: 0) }
      worked_minutes      { 360 }
      early_leave_minutes { 120 }
      status              { :early_leave }
    end

    trait :for_yesterday do
      date        { Date.yesterday }
      work_date   { Date.yesterday }
      check_in_at { Date.yesterday.to_time.change(hour: 9) }
    end

    trait :overnight do
      check_in_at    { Date.current.to_time.change(hour: 13) }
      check_out_at   { (Date.current + 1.day).to_time.change(hour: 1) }
      worked_minutes { 720 }
      status         { :present }
    end
  end
end
