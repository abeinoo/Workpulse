# One version of an EmployeeDataRequest's employee data + ID photos: either a
# manager's submission or a reviewer's correction (source). Immutable once
# created — a resubmission or correction appends a new revision, so every value
# ever submitted, and every change a reviewer made, stays in the history.
class EmployeeDataRequestRevision < ApplicationRecord
  include Attachable

  class ImmutableRevisionError < StandardError; end

  SOURCES = %w[submission reviewer_correction].freeze

  # Employee basic-data fields, in form order. Each maps 1:1 onto an existing
  # users column (see EmployeeDataRequests::EmployeeAttributes).
  # Address is optional (as on the employee record). The emergency phone, hire
  # date and ID expiry are required so every approved employee has them.
  REQUIRED_FIELDS = %i[
    full_name national_id phone_number date_of_birth
    identity_card_expiry_date hire_date emergency_contact_phone
  ].freeze
  DATA_FIELDS = %i[
    full_name national_id identity_card_expiry_date date_of_birth
    phone_number address
    job_title hire_date
    emergency_contact_name emergency_contact_phone emergency_contact_relationship
  ].freeze
  DATE_FIELDS = %i[date_of_birth identity_card_expiry_date hire_date].freeze
  LTR_FIELDS  = %i[national_id phone_number emergency_contact_phone].freeze
  # Form / review-page grouping.
  FIELD_GROUPS = {
    personal:  %i[full_name date_of_birth phone_number address],
    identity:  %i[national_id identity_card_expiry_date],
    job:       %i[job_title hire_date],
    emergency: %i[emergency_contact_name emergency_contact_phone emergency_contact_relationship]
  }.freeze

  # Arabic-Indic (٠-٩) and Extended Arabic-Indic / Persian (۰-۹) digits → ASCII,
  # so a number typed on an Arabic phone keyboard validates and matches.
  ARABIC_DIGITS = "٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹".freeze
  ASCII_DIGITS  = "01234567890123456789".freeze

  def self.normalize_digits(value)
    value.to_s.tr(ARABIC_DIGITS, ASCII_DIGITS)
  end

  def self.normalize_phone(value)
    return nil if value.blank?

    ascii  = normalize_digits(value).strip
    digits = ascii.gsub(/\D/, "")
    ascii.start_with?("+") ? "+#{digits}" : digits
  end

  belongs_to :employee_data_request, inverse_of: :revisions
  belongs_to :submitted_by, class_name: "User"

  has_one_attached :id_front
  has_one_attached :id_back

  validates_attachment :id_front,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE
  validates_attachment :id_back,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE

  normalizes :full_name,    with: ->(v) { v.to_s.squish }
  normalizes :national_id,  with: ->(v) { normalize_digits(v).gsub(/\s|-/, "") }
  normalizes :phone_number, :emergency_contact_phone, with: ->(v) { normalize_phone(v) }
  normalizes :address,       with: ->(v) { v.to_s.strip.presence }
  normalizes :job_title, :emergency_contact_name, :emergency_contact_relationship,
             with: ->(v) { v.to_s.squish.presence }
  normalizes :manager_notes, with: ->(v) { v.to_s.strip.presence }

  validates :source, inclusion: { in: SOURCES }
  validates(*REQUIRED_FIELDS, presence: true)
  validates :revision_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  # Egyptian national ID: exactly 14 digits (stricter than, and on top of, the
  # employee form's own rules — see #valid_as_employee).
  validates :national_id, format: { with: /\A\d{14}\z/, message: :invalid_national_id }, allow_blank: true
  validates :phone_number, :emergency_contact_phone, format: { with: /\A\+?\d{8,15}\z/ }, allow_blank: true
  validates :full_name, length: { maximum: 150 }
  validates :address,   length: { maximum: 500 }
  validates :job_title, :emergency_contact_name, :emergency_contact_relationship, length: { maximum: 100 }
  validates :manager_notes, length: { maximum: 2000 }
  validate  :full_name_has_two_parts
  validate  :dates_plausible
  validate  :id_front_attached
  validate  :id_back_attached
  validate  :valid_as_employee

  before_update  { raise ImmutableRevisionError, "employee data request revisions are immutable" }
  before_destroy(prepend: true) { raise ImmutableRevisionError, "employee data request revisions are immutable" }

  def submission?          = source == "submission"
  def reviewer_correction? = source == "reviewer_correction"

  # The employee record splits the name: first word → first_name, the rest →
  # last_name (full_name reassembles it unchanged).
  def name_parts
    first, rest = full_name.to_s.split(" ", 2)
    [ first, rest.to_s ]
  end

  # Data-field values, for pre-filling a resubmission / correction.
  def data_attributes
    DATA_FIELDS.index_with { |f| public_send(f) }
  end

  # Data fields whose value differs from `other`.
  def changed_data_fields_since(other)
    return [] unless other

    DATA_FIELDS.reject { |f| public_send(f) == other.public_send(f) }
  end

  # Everything that differs from `other` (the previous revision): data fields,
  # notes, and ID photos when a new file was uploaded. Drives the history diff.
  def changed_fields_since(other)
    return [] unless other

    fields = changed_data_fields_since(other)
    fields << :manager_notes if manager_notes != other.manager_notes
    fields << :id_front if id_front.blob&.id != other.id_front.blob&.id
    fields << :id_back  if id_back.blob&.id  != other.id_back.blob&.id
    fields
  end

  private

  def business
    employee_data_request&.business
  end

  def today
    business ? BusinessDay.current(context: business) : Date.current
  end

  def full_name_has_two_parts
    return if full_name.blank?

    errors.add(:full_name, :needs_two_parts) if full_name.split.size < 2
  end

  def dates_plausible
    if date_of_birth
      errors.add(:date_of_birth, :in_future) if date_of_birth > today
      errors.add(:date_of_birth, :too_old)   if date_of_birth < Date.new(1900, 1, 1)
    end
    return unless date_of_birth

    errors.add(:hire_date, :before_birth) if hire_date && hire_date <= date_of_birth
    errors.add(:identity_card_expiry_date, :before_birth) if identity_card_expiry_date && identity_card_expiry_date <= date_of_birth
  end

  def id_front_attached
    errors.add(:id_front, :blank) unless id_front.attached?
  end

  def id_back_attached
    errors.add(:id_back, :blank) unless id_back.attached?
  end

  # Runs the employee (User) model's own validations on the employee this
  # revision would create — uniqueness of phone / national ID, lengths, date of
  # birth — so the request enforces exactly what the employee form enforces.
  # Errors map back onto the request field; fields that already failed a
  # request-level rule aren't reported twice.
  def valid_as_employee
    return unless employee_data_request

    user = EmployeeDataRequests::EmployeeAttributes.build_user(self, business_id: employee_data_request.business_id)
    return if user.valid?

    already_invalid = errors.attribute_names.to_set
    user.errors.each do |error|
      field = EmployeeDataRequests::EmployeeAttributes::USER_TO_REVISION[error.attribute]
      next if field.nil? || already_invalid.include?(field)
      next if errors.added?(field, error.type, **error.options.slice(:count))

      errors.add(field, error.type, **error.options.slice(:count))
    end
  end
end
