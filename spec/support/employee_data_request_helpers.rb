module EmployeeDataRequestHelpers
  EDR_REQUESTER_PERMISSIONS = %i[create_employee_requests view_employee_requests].freeze
  EDR_REVIEWER_PERMISSIONS  = %i[view_employee_requests view_all_employee_requests review_employee_requests
                                 approve_employee_requests reject_employee_requests request_employee_changes].freeze

  def edr_user_with(*permissions, business:, scopes: {}, **attrs)
    role = create(:permission_role, business: business, permissions: permissions.map(&:to_s),
                                    permission_scopes: scopes.transform_keys(&:to_s))
    create(:user, business: business, permission_role: role, **attrs)
  end

  # Requester: create + view own.
  def edr_manager(business:, **attrs) = edr_user_with(*EDR_REQUESTER_PERMISSIONS, business: business, **attrs)

  # Full reviewer/approver, business-wide (an HR-style role).
  def edr_reviewer(business:, **attrs)
    edr_user_with(*EDR_REVIEWER_PERMISSIONS, business: business,
                  scopes: { view_all_employee_requests: "business" }, **attrs)
  end

  DEFAULT_JOB_TITLES = [ "كوافير", "مديرة صالون", "ريسبشن" ].freeze

  # The business's managed job-title list (the dropdown's source of truth).
  def seed_job_titles(business, names = DEFAULT_JOB_TITLES)
    names.each { |name| JobTitle.find_or_create_by!(business: business, name: name) }
  end

  def id_photo(name = "test_image.png", type = "image/png")
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files", name), type)
  end

  def edr_params(**overrides)
    {
      full_name:     "محمد أحمد علي حسن",
      national_id:   "29501011234567",
      phone_number:  "01001234567",
      address:       "15 شارع التحرير، الدقي، الجيزة",
      date_of_birth: "1995-01-01",
      identity_card_expiry_date:      "2031-05-20",
      job_title:                      "كوافير",
      hire_date:                      "2026-10-01",
      emergency_contact_name:         "فاطمة حسن",
      emergency_contact_phone:        "01229876543",
      emergency_contact_relationship: "والدة",
      manager_notes: nil,
      id_front:      id_photo,
      id_back:       id_photo
    }.merge(overrides)
  end
end

RSpec.configure { |c| c.include EmployeeDataRequestHelpers }
RSpec::Matchers.define_negated_matcher :not_include, :include unless RSpec::Matchers.method_defined?(:not_include)
