require "rails_helper"

# BUG-034 — a laundry batch never names another business's towel type or
# operator, through the service (and the model under it) or a crafted request.
RSpec.describe "Laundry batch business guards (BUG-034)", type: :model do
  let(:business)       { create(:business) }
  let(:actor)          { create(:user, business: business) }
  let(:laundry)        { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type)     { business.towel_types.create!(name: "Bath Towel") }
  let(:other)          { create(:business) }
  let(:foreign_towel)  { other.towel_types.create!(name: "Foreign Towel") }
  let(:foreign_person) { create(:user, business: other) }

  def create_batch(**ids)
    Laundry::LaundryBatchService.create(actor: actor, laundry_branch_id: laundry.id,
                                        **{ towel_type_id: towel_type.id }.merge(ids))
  end

  it "refuses another business's towel type, writing no batch or ledger entry" do
    expect { @result = create_batch(towel_type_id: foreign_towel.id) }
      .not_to change { [ LaundryBatch.count, TowelLedgerEntry.count ] }
    expect(@result).not_to be_ok
    expect(@result.batch.errors.where(:towel_type_id, :other_business)).to be_present
  end

  it "refuses another business's operator" do
    expect { @result = create_batch(operator_id: foreign_person.id) }.not_to change(LaundryBatch, :count)
    expect(@result.batch.errors.where(:operator_id, :other_business)).to be_present
  end

  it "refuses an existing batch updated to a foreign towel type or operator" do
    batch = create_batch.batch

    expect(batch.update(towel_type: foreign_towel)).to be(false)
    expect(batch.reload.update(operator: foreign_person)).to be(false)
    expect(batch.reload).to have_attributes(towel_type_id: towel_type.id, operator_id: nil)
  end

  it "accepts the business's own towel type and operator, and no operator at all" do
    expect(create_batch(operator_id: actor.id)).to be_ok
    expect(create_batch).to be_ok
  end
end
