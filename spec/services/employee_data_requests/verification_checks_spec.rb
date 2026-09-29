require "rails_helper"

RSpec.describe EmployeeDataRequests::VerificationChecks do
  let(:today) { Date.new(2026, 9, 29) }

  def checks(**attrs)
    revision = EmployeeDataRequestRevision.new({ national_id: "29504121234567", date_of_birth: Date.new(1995, 4, 12),
                                                 identity_card_expiry_date: Date.new(2031, 1, 1),
                                                 hire_date: Date.new(2026, 10, 1) }.merge(attrs))
    described_class.for(revision, today: today).index_by(&:key)
  end

  it "confirms the birth date encoded in the national ID" do
    expect(checks).to include(:national_id_matches_birth_date)
    expect(described_class.birth_date_from_national_id("30101150123456")).to eq(Date.new(2001, 1, 15))
  end

  it "flags a birth date that doesn't match the national ID" do
    check = checks(date_of_birth: Date.new(1996, 4, 12))[:national_id_birth_date_mismatch]
    expect(check).to be_warning
    expect(check.params[:encoded]).to eq(Date.new(1995, 4, 12))
  end

  it "flags expired, soon-expiring and missing ID expiry dates" do
    expect(checks(identity_card_expiry_date: Date.new(2026, 1, 1))).to include(:id_expired)
    expect(checks(identity_card_expiry_date: Date.new(2026, 10, 15))).to include(:id_expiring_soon)
    expect(checks(identity_card_expiry_date: nil)).to include(:id_expiry_missing)
    expect(checks).to include(:id_valid)
  end

  it "flags an employee under 18 on the hire date" do
    expect(checks(national_id: "31001011234567", date_of_birth: Date.new(2010, 1, 1))[:age_at_hire_minor].params[:age]).to eq(16)
    expect(checks).to include(:age_at_hire_ok)
  end
end
