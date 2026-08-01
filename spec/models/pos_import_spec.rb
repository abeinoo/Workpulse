require "rails_helper"

RSpec.describe PosImport do
  it "is valid with a file_name and a valid status" do
    pos_import = build(:pos_import)
    expect(pos_import).to be_valid
  end

  it "requires a file_name" do
    pos_import = build(:pos_import, file_name: nil)
    expect(pos_import).not_to be_valid
    expect(pos_import.errors[:file_name]).to be_present
  end

  it "rejects a status outside STATUSES" do
    pos_import = build(:pos_import, status: "bogus")
    expect(pos_import).not_to be_valid
  end

  describe "#pending?/#imported?/#failed?" do
    it "reflects the status" do
      expect(build(:pos_import, status: "pending")).to be_pending
      expect(build(:pos_import, status: "imported")).to be_imported
      expect(build(:pos_import, status: "failed")).to be_failed
    end
  end

  it "destroys its pos_transactions when destroyed" do
    pos_import = create(:pos_import)
    create(:pos_transaction, pos_import: pos_import, business: pos_import.business)

    expect { pos_import.destroy }.to change(PosTransaction, :count).by(-1)
  end
end
