FactoryBot.define do
  # A pending employee data request with one complete revision (both ID photos).
  factory :employee_data_request do
    business
    submitted_by { association :user, business: business }
    status       { "pending_review" }

    transient do
      full_name     { "محمد أحمد علي حسن" }
      sequence(:national_id) { |n| (29_001_010_000_000 + n).to_s }
      sequence(:phone_number) { |n| "0100#{format('%07d', n)}" }
      address       { "15 شارع التحرير، الدقي، الجيزة" }
      date_of_birth { Date.new(1995, 4, 12) }
      identity_card_expiry_date      { Date.new(2031, 5, 20) }
      job_title                      { "كوافير" }
      hire_date                      { Date.new(2026, 10, 1) }
      emergency_contact_name         { "فاطمة حسن" }
      emergency_contact_phone        { "01229876543" }
      emergency_contact_relationship { "والدة" }
      manager_notes { nil }
    end

    after(:build) do |request, ev|
      JobTitle.find_or_create_by!(business: request.business, name: ev.job_title) if ev.job_title
      request.revisions.build(
        revision_number: 1, submitted_by: request.submitted_by,
        full_name: ev.full_name, national_id: ev.national_id, phone_number: ev.phone_number,
        address: ev.address, date_of_birth: ev.date_of_birth, manager_notes: ev.manager_notes,
        identity_card_expiry_date: ev.identity_card_expiry_date, job_title: ev.job_title, hire_date: ev.hire_date,
        emergency_contact_name: ev.emergency_contact_name, emergency_contact_phone: ev.emergency_contact_phone,
        emergency_contact_relationship: ev.emergency_contact_relationship,
        id_front: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/test_image.png"), "image/png"),
        id_back:  Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/test_image.png"), "image/png")
      )
    end

    after(:create) do |request|
      request.events.create!(actor: request.submitted_by, action: "submitted", revision: request.revisions.first)
    end
  end
end
