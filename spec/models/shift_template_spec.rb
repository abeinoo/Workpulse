require "rails_helper"

RSpec.describe ShiftTemplate, type: :model do
  let(:business)    { create(:business) }
  let(:creator)     { create(:user, business: business) }

  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to belong_to(:created_by).class_name("User") }
    it { is_expected.to have_many(:entries).class_name("ShiftTemplateEntry").dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:shift_template, business: business, created_by: creator) }

    it { is_expected.to validate_presence_of(:name) }
    it "rejects duplicate names within the same business (case-insensitive)" do
      create(:shift_template, business: business, created_by: creator, name: "Ramadan")
      dup = build(:shift_template, business: business, created_by: creator, name: "ramadan")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end

    it "is invalid without a business" do
      template = build(:shift_template, created_by: creator)
      template.business = nil
      expect(template).not_to be_valid
    end

    it "is invalid without a created_by" do
      template = build(:shift_template, business: business)
      template.created_by = nil
      expect(template).not_to be_valid
    end

    it "allows duplicate names across different businesses" do
      other_business = create(:business)
      create(:shift_template, business: business, created_by: creator, name: "Ramadan")
      other = build(:shift_template, business: other_business,
                    created_by: create(:user, business: other_business), name: "Ramadan")
      expect(other).to be_valid
    end
  end

  describe "scopes" do
    let!(:active_template)   { create(:shift_template, business: business, created_by: creator) }
    let!(:archived_template) { create(:shift_template, :archived, business: business, created_by: creator) }

    describe ".active" do
      it "returns templates with nil archived_at" do
        expect(ShiftTemplate.active).to include(active_template)
        expect(ShiftTemplate.active).not_to include(archived_template)
      end
    end

    describe ".archived" do
      it "returns templates with a non-nil archived_at" do
        expect(ShiftTemplate.archived).to include(archived_template)
        expect(ShiftTemplate.archived).not_to include(active_template)
      end
    end

    describe ".for_business" do
      let(:other_business) { create(:business) }
      let!(:other_template) do
        create(:shift_template, business: other_business,
               created_by: create(:user, business: other_business))
      end

      it "returns only templates for the given business" do
        expect(ShiftTemplate.for_business(business)).to include(active_template)
        expect(ShiftTemplate.for_business(business)).not_to include(other_template)
      end
    end
  end

  describe "#archived?" do
    it "returns false when archived_at is nil" do
      template = build(:shift_template)
      expect(template.archived?).to be false
    end

    it "returns true when archived_at is set" do
      template = build(:shift_template, :archived)
      expect(template.archived?).to be true
    end
  end

  describe "#archive!" do
    it "sets archived_at to the current time" do
      template = create(:shift_template, business: business, created_by: creator)
      freeze_time do
        template.archive!
        expect(template.reload.archived_at).to be_within(1.second).of(Time.current)
      end
    end
  end

  describe "#unarchive!" do
    it "clears archived_at" do
      template = create(:shift_template, :archived, business: business, created_by: creator)
      template.unarchive!
      expect(template.reload.archived_at).to be_nil
    end
  end

  describe "entries cascade delete" do
    it "destroys entries when the template is destroyed" do
      template = create(:shift_template, :with_entry, business: business, created_by: creator)
      entry_id = template.entries.first.id
      template.destroy!
      expect(ShiftTemplateEntry.exists?(entry_id)).to be false
    end
  end
end
