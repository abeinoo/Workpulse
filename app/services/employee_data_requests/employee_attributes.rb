module EmployeeDataRequests
  # The single mapping between an employee data request revision and the
  # employee (User) record it becomes on approval. Used both to create the
  # employee and to validate a revision with the SAME rules as the employee
  # creation form (a request can never be weaker than the employee form).
  #
  # Personal / basic data only: branch, salary, role/permissions, shifts,
  # commission and payroll settings are deliberately absent and are configured
  # on the employee afterwards.
  module EmployeeAttributes
    # revision field → users column (full_name splits into first/last name).
    DIRECT_FIELDS = {
      national_id:                    :identity_card_number,
      identity_card_expiry_date:      :identity_card_expiry_date,
      phone_number:                   :phone_number,
      address:                        :address,
      date_of_birth:                  :date_of_birth,
      job_title:                      :job_title,
      hire_date:                      :hire_date,
      emergency_contact_name:         :emergency_contact_name,
      emergency_contact_phone:        :emergency_contact_phone,
      emergency_contact_relationship: :emergency_contact_relationship
    }.freeze

    # users column → revision field, for mapping employee validation errors back.
    USER_TO_REVISION = DIRECT_FIELDS.invert.merge(first_name: :full_name, last_name: :full_name).freeze

    module_function

    def for(revision)
      first_name, last_name = revision.name_parts
      DIRECT_FIELDS.each_with_object(first_name: first_name, last_name: last_name) do |(field, column), attrs|
        attrs[column] = revision.public_send(field).presence
      end
    end

    def build_user(revision, business_id:)
      User.new(self.for(revision).merge(business_id: business_id))
    end
  end
end
