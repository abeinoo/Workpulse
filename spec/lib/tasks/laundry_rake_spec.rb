require "rails_helper"
require "rake"

# BUG-029 (D6) — laundry:reset_test_balances zeroes active branches exactly as
# before and skips inactive ones: no adjustment there, and an in-transit
# transfer from an inactive source is left untouched.
RSpec.describe "laundry:reset_test_balances" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("laundry:reset_test_balances") }

  let(:task)       { Rake::Task["laundry:reset_test_balances"] }
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:active)     { create(:branch, business: business, branch_type: "sales", name: "Open") }
  let(:inactive)   { create(:branch, business: business, branch_type: "sales", name: "Closed") }
  let(:laundry)    { create(:branch, business: business, branch_type: "laundry", name: "Laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  def fund(branch, quantity)
    Laundry::TowelAdjuster.new(actor: owner).call(towel_type: towel_type, branch: branch, status: "clean",
                                                  adjustment_quantity: quantity, reason: "setup")
  end

  def clean_at(branch) = Laundry::TowelBalances.new(towel_type).at_branch(branch, "clean")

  before do
    task.reenable
    allow(Rails.env).to receive(:development?).and_return(true)
  end

  it "zeroes active branches and leaves inactive ones and their in-transit transfers untouched" do
    fund(active, 7)
    fund(inactive, 12)
    in_transit = Laundry::TowelTransferCreator.create(actor: owner, params: {
      source_branch_id: inactive.id, destination_branch_id: laundry.id, towel_status: "dirty",
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 2 } ]
    }).transfer
    Laundry::TowelTransferCreator.new(in_transit).dispatch(actor: owner)
    inactive.update_column(:active, false)
    entries_before = TowelLedgerEntry.where(branch_id: inactive.id).count

    expect { task.invoke }.to output(/Skipped 1 in-transit transfer.*Skipped inactive branch\(es\): .*Closed/m).to_stdout

    expect(clean_at(active)).to eq(0)
    expect(clean_at(inactive)).to eq(10)
    expect(TowelLedgerEntry.where(branch_id: inactive.id).count).to eq(entries_before)
    expect(in_transit.reload).to be_dispatched
  end
end
