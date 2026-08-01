require "rails_helper"

RSpec.describe Finance::PosImports::SummaryBuilder do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def build_row(transaction_id: "TXN-1", amount: "100.00", fees: "0", administrative_fees: "0", status: "Success")
    Finance::PosImports::Mapper::MappedRow.new(
      row_number: 1,
      attributes: { transaction_id: transaction_id, amount: amount, terminal_id: "TERM-1",
                    fees: fees, administrative_fees: administrative_fees, status: status }
    )
  end

  def no_ignored
    Finance::PosImports::StatusFilter::Result.new(included_rows: [], ignored_rows: [])
  end

  describe ".for_preview" do
    it "excludes branches with zero fees from expenses_to_generate" do
      create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")
      row = build_row(fees: "0", administrative_fees: "0")
      resolution = Finance::PosImports::BranchResolver.call([ row ], business: business)
      validation = Finance::PosImports::Validator::ValidationResult.new(valid_rows: [ row ], invalid_rows: [])

      summary = described_class.for_preview(mapped_rows: [ row ], status_split: no_ignored,
                                            validation: validation, resolution: resolution, business: business)

      expect(summary["expenses_to_generate"]).to be_empty
      expect(summary["total_transactions"]).to eq(1)
    end

    it "includes branches with nonzero fees" do
      create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")
      row = build_row(fees: "5.00", administrative_fees: "1.00")
      resolution = Finance::PosImports::BranchResolver.call([ row ], business: business)
      validation = Finance::PosImports::Validator::ValidationResult.new(valid_rows: [ row ], invalid_rows: [])

      summary = described_class.for_preview(mapped_rows: [ row ], status_split: no_ignored,
                                            validation: validation, resolution: resolution, business: business)

      expect(summary["expenses_to_generate"].size).to eq(1)
      expect(summary["expenses_to_generate"].first["branch_name"]).to eq(branch.name)
      expect(summary["expenses_to_generate"].first["total_fees"].to_d).to eq(6.0.to_d)
    end

    it "reports ignored_count and ignored_amount from status_split, separate from valid/invalid" do
      create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")
      included_row = build_row(transaction_id: "TXN-1", amount: "100.00", status: "Success")
      ignored_row_1 = build_row(transaction_id: "TXN-2", amount: "30.00", status: "Failed")
      ignored_row_2 = build_row(transaction_id: "TXN-3", amount: "20.00", status: "Declined")
      status_split = Finance::PosImports::StatusFilter::Result.new(
        included_rows: [ included_row ], ignored_rows: [ ignored_row_1, ignored_row_2 ]
      )
      resolution = Finance::PosImports::BranchResolver.call([ included_row ], business: business)
      validation = Finance::PosImports::Validator::ValidationResult.new(valid_rows: [ included_row ], invalid_rows: [])

      summary = described_class.for_preview(
        mapped_rows: [ included_row, ignored_row_1, ignored_row_2 ], status_split: status_split,
        validation: validation, resolution: resolution, business: business
      )

      expect(summary["ignored_count"]).to eq(2)
      expect(summary["ignored_amount"].to_d).to eq(50.0.to_d)
      expect(summary["total_amount"].to_d).to eq(100.0.to_d)
    end

    it "includes manually_ignored_rows (row_number, reason, ignored_by, ignored_at) when a pos_import is given" do
      create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")
      user = create(:user, business: business, first_name: "Ahmed", last_name: "Ali")
      pos_import = create(:pos_import, business: business)
      create(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: user,
             row_number: 9, reason: "Corrupted row")
      row = build_row
      resolution = Finance::PosImports::BranchResolver.call([ row ], business: business)
      validation = Finance::PosImports::Validator::ValidationResult.new(valid_rows: [ row ], invalid_rows: [])

      summary = described_class.for_preview(mapped_rows: [ row ], status_split: no_ignored,
                                            validation: validation, resolution: resolution, business: business,
                                            pos_import: pos_import)

      expect(summary["manually_ignored_rows"].size).to eq(1)
      expect(summary["manually_ignored_rows"].first["row_number"]).to eq(9)
      expect(summary["manually_ignored_rows"].first["reason"]).to eq("Corrupted row")
      expect(summary["manually_ignored_rows"].first["ignored_by"]).to eq("Ahmed Ali")
    end

    it "returns an empty manually_ignored_rows list when no pos_import is given" do
      row = build_row
      resolution = Finance::PosImports::BranchResolver.call([ row ], business: business)
      validation = Finance::PosImports::Validator::ValidationResult.new(valid_rows: [ row ], invalid_rows: [])

      summary = described_class.for_preview(mapped_rows: [ row ], status_split: no_ignored,
                                            validation: validation, resolution: resolution, business: business)

      expect(summary["manually_ignored_rows"]).to eq([])
    end

    it "is safe to persist as jsonb and reload with the same shape (no AR objects, string keys)" do
      create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")
      row = build_row(fees: "5.00", administrative_fees: "0")
      resolution = Finance::PosImports::BranchResolver.call([ row ], business: business)
      validation = Finance::PosImports::Validator::ValidationResult.new(valid_rows: [ row ], invalid_rows: [])
      summary    = described_class.for_preview(mapped_rows: [ row ], status_split: no_ignored,
                                               validation: validation, resolution: resolution, business: business)

      pos_import = create(:pos_import, business: business)
      pos_import.update_column(:preview_data, summary)
      reloaded = pos_import.reload.preview_data

      expect(reloaded).to eq(summary)
      expect(reloaded["expenses_to_generate"].first["branch_name"]).to eq(branch.name)
    end
  end

  describe ".for_import" do
    it "reads the persisted summary columns off the PosImport" do
      pos_import = create(:pos_import, business: business,
                          total_rows: 5, imported_rows: 3, duplicate_rows: 1, invalid_rows: 1,
                          ignored_rows: 1, ignored_amount: 25,
                          total_amount: 150, total_fees: 10, expenses_created_count: 2)
      create(:pos_transaction, business: business, pos_import: pos_import, branch: branch)

      summary = described_class.for_import(pos_import)

      expect(summary[:total_rows]).to eq(5)
      expect(summary[:imported_rows]).to eq(3)
      expect(summary[:duplicate_rows]).to eq(1)
      expect(summary[:invalid_rows]).to eq(1)
      expect(summary[:ignored_rows]).to eq(1)
      expect(summary[:ignored_amount]).to eq(25)
      expect(summary[:total_amount]).to eq(150)
      expect(summary[:total_fees]).to eq(10)
      expect(summary[:expenses_created]).to eq(2)
      expect(summary[:detected_branches]).to eq([ branch.name ])
    end
  end
end
