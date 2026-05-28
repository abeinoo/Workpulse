require "rails_helper"

RSpec.describe ShiftTemplatePolicy, type: :model do
  let(:business)     { create(:business) }
  let(:owner)        { create(:user, :super_admin, business: business) }
  let(:manager)      { create(:user, :branch_manager, business: business) }
  let(:employee)     { create(:user, business: business) }

  let(:template) { create(:shift_template, business: business, created_by: owner) }

  subject { described_class }

  describe "index?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "show?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "create?" do
    it "permits owner"    do expect(subject).to     permit(owner,    ShiftTemplate.new) end
    it "permits manager"  do expect(subject).to     permit(manager,  ShiftTemplate.new) end
    it "denies employee"  do expect(subject).not_to permit(employee, ShiftTemplate.new) end
  end

  describe "update?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "archive?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "unarchive?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "apply?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "preview_apply?" do
    it "permits owner"    do expect(subject).to     permit(owner,    template) end
    it "permits manager"  do expect(subject).to     permit(manager,  template) end
    it "denies employee"  do expect(subject).not_to permit(employee, template) end
  end

  describe "Scope" do
    it "returns templates for the current user's business" do
      other_business = create(:business)
      other_creator  = create(:user, business: other_business)
      other_template = create(:shift_template, business: other_business, created_by: other_creator)

      scope = described_class::Scope.new(owner, ShiftTemplate).resolve
      expect(scope).to include(template)
      expect(scope).not_to include(other_template)
    end
  end
end
