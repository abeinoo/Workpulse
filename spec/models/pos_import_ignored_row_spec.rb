require "rails_helper"

RSpec.describe PosImportIgnoredRow do
  let(:business)   { create(:business) }
  let(:pos_import) { create(:pos_import, business: business) }
  let(:user)       { create(:user, business: business) }

  it "is valid with a row_number, reason, and ignored_by" do
    row = build(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user)
    expect(row).to be_valid
  end

  it "requires a reason" do
    row = build(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user, reason: nil)
    expect(row).not_to be_valid
    expect(row.errors[:reason]).to be_present
  end

  it "requires a row_number" do
    row = build(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user, row_number: nil)
    expect(row).not_to be_valid
  end

  it "prevents ignoring the same row twice for the same import" do
    create(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user, row_number: 9)
    dup = build(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user, row_number: 9)

    expect(dup).not_to be_valid
    expect(dup.errors[:row_number]).to be_present
  end

  it "allows the same row_number across different imports" do
    other_import = create(:pos_import, business: business)
    create(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user, row_number: 9)

    other = build(:pos_import_ignored_row, pos_import: other_import, business: business, ignored_by: user, row_number: 9)
    expect(other).to be_valid
  end

  it "defaults business_id from the pos_import" do
    row = PosImportIgnoredRow.new(pos_import: pos_import, ignored_by: user, row_number: 1, reason: "test")
    row.valid?
    expect(row.business_id).to eq(business.id)
  end
end
