require "rails_helper"

# R6: the business-wide Holiday Calendar (attendance plan A10, D3).
RSpec.describe Holiday, type: :model do
  let(:business) { create(:business) }
  let(:hr)       { create(:user, business: business) }

  it "records public and company holidays only" do
    expect(build(:holiday, created_by: hr, kind: "public")).to be_valid
    expect(build(:holiday, created_by: hr, kind: "company")).to be_valid
    expect(build(:holiday, created_by: hr, kind: "regional")).not_to be_valid
  end

  it "requires a date and a name" do
    expect(build(:holiday, created_by: hr, date: nil)).not_to be_valid
    expect(build(:holiday, created_by: hr, name: "")).not_to be_valid
  end

  it "allows one holiday per business and date, in the model and the database" do
    create(:holiday, created_by: hr, date: Date.new(2026, 7, 23))
    expect(build(:holiday, created_by: hr, date: Date.new(2026, 7, 23))).not_to be_valid
    expect { build(:holiday, created_by: hr, date: Date.new(2026, 7, 23)).save!(validate: false) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    other = create(:user, business: create(:business))
    expect(build(:holiday, created_by: other, date: Date.new(2026, 7, 23))).to be_valid
  end

  it "refuses a creator from another business and an unknown kind in the database" do
    stranger = create(:user, business: create(:business))
    expect(build(:holiday, created_by: stranger, business: business).tap(&:valid?).errors).to be_of_kind(:created_by, :other_business)
    expect { build(:holiday, created_by: hr, kind: "regional").save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /holidays_kind_known/)
  end

  it "has no branch: the calendar is business-wide (D3)" do
    expect(described_class.column_names).not_to include("branch_id")
  end

  it "lists a year in date order" do
    late  = create(:holiday, created_by: hr, date: Date.new(2026, 10, 6))
    early = create(:holiday, created_by: hr, date: Date.new(2026, 1, 7))
    create(:holiday, created_by: hr, date: Date.new(2027, 1, 7))
    expect(described_class.for_business(business).in_year(2026).ordered).to eq([ early, late ])
  end
end
