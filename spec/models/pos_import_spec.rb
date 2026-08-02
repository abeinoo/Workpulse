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

  it "destroys its pos_transactions when destroyed while still pending" do
    pos_import = create(:pos_import, status: "pending")
    create(:pos_transaction, pos_import: pos_import, business: pos_import.business)

    expect { pos_import.destroy }.to change(PosTransaction, :count).by(-1)
  end

  describe "#deletable?" do
    it "is true while pending" do
      expect(build(:pos_import, status: "pending")).to be_deletable
    end

    it "is true once failed — nothing was persisted, so there's nothing to protect" do
      expect(build(:pos_import, status: "failed")).to be_deletable
    end

    it "is false once imported" do
      expect(build(:pos_import, status: "imported")).not_to be_deletable
    end
  end

  describe "deletion once imported" do
    it "raises and leaves everything intact rather than silently erasing a confirmed import's PosTransaction rows" do
      pos_import = create(:pos_import, status: "imported")
      create(:pos_transaction, pos_import: pos_import, business: pos_import.business)

      expect { pos_import.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
      expect(PosImport.exists?(pos_import.id)).to be true
      expect(PosTransaction.where(pos_import: pos_import).count).to eq(1)
    end

    it "still allows deleting a failed import (rolled back, nothing downstream to protect)" do
      pos_import = create(:pos_import, status: "failed")

      expect { pos_import.destroy }.not_to raise_error
      expect(PosImport.exists?(pos_import.id)).to be false
    end
  end
end
