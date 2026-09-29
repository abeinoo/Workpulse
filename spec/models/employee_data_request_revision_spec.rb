require "rails_helper"

RSpec.describe EmployeeDataRequestRevision do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business) }
  let(:request)  { EmployeeDataRequest.new(business: business, submitted_by: manager) }

  def invalid_fields(revision) = revision.valid? ? [] : revision.errors.attribute_names

  def build_revision(**overrides)
    attrs = edr_params(**overrides)
    request.revisions.build(attrs.merge(revision_number: 1, submitted_by: manager))
  end

  it "is valid with every required field and both ID photos" do
    expect(build_revision).to be_valid
  end

  %i[full_name national_id phone_number date_of_birth identity_card_expiry_date hire_date
     emergency_contact_phone].each do |field|
    it "requires #{field}" do
      revision = build_revision(field => "")
      expect(revision).not_to be_valid
      expect(revision.errors[field]).to be_present
    end
  end

  it "requires the ID front photo" do
    revision = build_revision(id_front: nil)
    expect(revision).not_to be_valid
    expect(revision.errors[:id_front]).to be_present
  end

  it "requires the ID back photo" do
    revision = build_revision(id_back: nil)
    expect(revision).not_to be_valid
    expect(revision.errors[:id_back]).to be_present
  end

  it "accepts only images for the ID photos" do
    revision = build_revision(id_front: id_photo("test_document.pdf", "application/pdf"))
    expect(revision).not_to be_valid
    expect(revision.errors[:id_front]).to be_present
  end

  it "treats manager notes as optional" do
    expect(build_revision(manager_notes: nil)).to be_valid
    expect(build_revision(manager_notes: "تم الاتفاق على 9000 جنيه + عمولة")).to be_valid
  end

  it "requires a 14-digit national ID and normalizes Arabic-Indic digits" do
    expect(build_revision(national_id: "12345")).not_to be_valid
    revision = build_revision(national_id: "٢٩٥٠١٠١١٢٣٤٥٦٧")
    expect(revision).to be_valid
    expect(revision.national_id).to eq("29501011234567")
  end

  it "requires at least a first and last name" do
    expect(build_revision(full_name: "محمد")).not_to be_valid
  end

  it "rejects a date of birth in the future" do
    expect(build_revision(date_of_birth: (Date.current + 2).iso8601)).not_to be_valid
  end

  it "stores every employee basic-data field, normalized" do
    revision = build_revision(emergency_contact_phone: "٠١٢٢٩٨٧٦٥٤٣", job_title: "  كوافير  ")
    expect(revision).to be_valid
    expect(revision).to have_attributes(
      identity_card_expiry_date: Date.new(2031, 5, 20), job_title: "كوافير", hire_date: Date.new(2026, 10, 1),
      emergency_contact_name: "فاطمة حسن", emergency_contact_phone: "01229876543",
      emergency_contact_relationship: "والدة"
    )
  end

  it "treats the address, job title and emergency name/relationship as optional" do
    revision = build_revision(address: "", job_title: "",
                              emergency_contact_name: "", emergency_contact_relationship: "")
    expect(revision).to be_valid
    expect(revision.address).to be_nil
  end

  it "requires the emergency phone and validates it like the employee form" do
    missing = build_revision(emergency_contact_phone: "")
    expect(missing).not_to be_valid
    expect(missing.errors.of_kind?(:emergency_contact_phone, :blank)).to be(true)
    expect(build_revision(emergency_contact_phone: "0122")).not_to be_valid
    expect(build_revision(emergency_contact_phone: "٠١٢٢٩٨٧٦٥٤٣")).to be_valid
  end

  it "rejects an invalid hire date or ID expiry (e.g. 31 February) as missing" do
    expect(invalid_fields(build_revision(hire_date: "2026-02-31"))).to include(:hire_date)
    expect(invalid_fields(build_revision(identity_card_expiry_date: "not-a-date"))).to include(:identity_card_expiry_date)
  end

  it "rejects a hire date or ID expiry on/before the date of birth" do
    expect(invalid_fields(build_revision(hire_date: "1990-01-01"))).to include(:hire_date)
    expect(invalid_fields(build_revision(identity_card_expiry_date: "1990-01-01"))).to include(:identity_card_expiry_date)
  end

  describe "validation parity with the employee creation form (User model)" do
    let(:other_business) { create(:business) }

    # Each case must be rejected by BOTH the employee form's model and the request.
    {
      "national ID already used by any employee" => ->(t) { create(:user, business: t.other_business, identity_card_number: "29501011234567"); {} },
      "phone already used by any employee"       => ->(t) { create(:user, business: t.other_business, phone_number: "01001234567"); {} },
      "date of birth in the future"              => ->(_) { { date_of_birth: (Date.current + 5).iso8601 } },
      "emergency phone too short"                => ->(_) { { emergency_contact_phone: "1234" } },
      "address too long"                         => ->(_) { { address: "ش" * 501 } },
      "missing full name"                        => ->(_) { { full_name: "" } }
    }.each do |label, setup|
      it "rejects: #{label}" do
        overrides = instance_exec(self, &setup)
        revision  = build_revision(**overrides)
        user      = EmployeeDataRequests::EmployeeAttributes.build_user(revision, business_id: business.id)
        expect(user).not_to be_valid
        expect(revision).not_to be_valid
      end
    end

    it "maps employee-form uniqueness errors onto the request field" do
      create(:user, business: other_business, identity_card_number: "29501011234567")
      revision = build_revision
      revision.valid?
      expect(revision.errors.of_kind?(:national_id, :taken)).to be(true)
    end
  end

  it "has no branch, salary or employment attributes" do
    expect(described_class.column_names).not_to include("branch_id", "salary", "salary_type", "commission",
                                                        "permission_role_id", "shift_id")
    expect(EmployeeDataRequest.column_names).not_to include("branch_id", "salary", "permission_role_id", "shift_id")
  end

  it "is immutable once saved" do
    revision = build_revision
    request.save!
    expect { revision.update!(full_name: "اسم آخر كامل") }
      .to raise_error(EmployeeDataRequestRevision::ImmutableRevisionError)
    expect { revision.destroy }.to raise_error(EmployeeDataRequestRevision::ImmutableRevisionError)
  end
end
