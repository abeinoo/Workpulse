require "rails_helper"

RSpec.describe OperationsDashboardPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:owner)       { create(:user, :owner,          business: business) }
  let(:accountant)  { create(:user, :accountant,     business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:area_mgr)    { create(:user, :area_manager,   business: business) }
  let(:employee)    { create(:user,                  business: business) }

  subject { described_class }

  describe "index?" do
    it "permits owner"          do expect(subject.new(owner,      :operations_dashboard).index?).to be true end
    it "permits accountant"     do expect(subject.new(accountant, :operations_dashboard).index?).to be true end
    it "permits branch_manager" do expect(subject.new(manager,    :operations_dashboard).index?).to be true end
    it "permits area_manager"   do expect(subject.new(area_mgr,   :operations_dashboard).index?).to be true end
    it "denies plain employee"  do expect(subject.new(employee,   :operations_dashboard).index?).to be false end
  end
end
