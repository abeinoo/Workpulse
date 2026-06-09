require "rails_helper"

RSpec.describe PayrollAdjustment, type: :model do
  subject(:adjustment) { build(:payroll_adjustment) }

  describe "validations" do
    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:reason) }

    it "requires amount to be greater than zero" do
      adjustment.amount = 0
      expect(adjustment).not_to be_valid
      adjustment.amount = -1
      expect(adjustment).not_to be_valid
    end

    it "rejects unknown adjustment_type" do
      expect { adjustment.adjustment_type = "unknown" }.to raise_error(ArgumentError)
    end

    describe "user_belongs_to_business" do
      it "is valid when user belongs to the same business" do
        expect(adjustment).to be_valid
      end

      it "is invalid when user belongs to a different business" do
        adjustment.user = create(:user, business: create(:business))
        expect(adjustment).not_to be_valid
        expect(adjustment.errors[:user]).to be_present
      end
    end

    describe "creator_is_not_approver" do
      it "is invalid when approved_by equals created_by" do
        creator = adjustment.created_by
        adjustment.approved_by = creator
        expect(adjustment).not_to be_valid
        expect(adjustment.errors[:approved_by]).to be_present
      end

      it "is valid when approved_by differs from created_by" do
        adjustment.approved_by = create(:user, business: adjustment.business)
        expect(adjustment).to be_valid
      end

      it "is valid when approved_by is blank (pending)" do
        adjustment.approved_by = nil
        expect(adjustment).to be_valid
      end

      it "is valid when the business owner approves their own adjustment" do
        owner = create(:user, :owner, business: adjustment.business)
        adjustment.created_by  = owner
        adjustment.approved_by = owner
        expect(adjustment).to be_valid
      end
    end

    describe "owner auto-approval" do
      let(:business) { create(:business) }
      let(:owner)    { create(:user, :owner, business: business) }
      let(:period)   { create(:payroll_period, business: business, status: "draft") }

      def owner_adjustment
        build(:payroll_adjustment, payroll_period: period, business: business,
              created_by: owner, review_status: "pending_review")
      end

      it "#apply_owner_auto_approval approves an owner-created adjustment" do
        adj = owner_adjustment
        adj.apply_owner_auto_approval

        expect(adj.review_status).to eq("approved")
        expect(adj.approved_by_id).to eq(owner.id)
        expect(adj.reviewed_by_id).to eq(owner.id)
        expect(adj.approved_at).to be_present
        expect(adj).to be_valid
      end

      it "#apply_owner_auto_approval is a no-op for a non-owner creator" do
        adj = build(:payroll_adjustment, payroll_period: period, business: business,
                    created_by: create(:user, business: business),
                    review_status: "pending_review")
        adj.apply_owner_auto_approval

        expect(adj.review_status).to eq("pending_review")
        expect(adj.approved_by_id).to be_nil
      end

      it "#creator_is_business_owner? is true only when created_by is the owner" do
        expect(owner_adjustment.creator_is_business_owner?).to be true
        non_owner = build(:payroll_adjustment, payroll_period: period, business: business,
                          created_by: create(:user, business: business))
        expect(non_owner.creator_is_business_owner?).to be false
      end
    end

    describe "period_not_locked (payroll lock)" do
      let(:business) { create(:business) }
      let(:employee) { create(:user, business: business) }

      def standalone_adjustment(period)
        build(:payroll_adjustment,
              payroll_period: nil,
              business:       business,
              user:           employee,
              created_by:     create(:user, business: business),
              period_month:   period.period_month,
              period_year:    period.period_year)
      end

      it "blocks creation when payroll for the period is paid" do
        period = create(:payroll_period, :paid, business: business)
        adj = standalone_adjustment(period)
        expect(adj).not_to be_valid
        expect(adj.errors[:base])
          .to include(I18n.t("adjustments.errors.period_processed"))
      end

      it "blocks creation when payroll for the period is finalized" do
        period = create(:payroll_period, :finalized, business: business)
        adj = standalone_adjustment(period)
        expect(adj).not_to be_valid
        expect(adj.errors[:base])
          .to include(I18n.t("adjustments.errors.period_processed"))
      end

      it "blocks creation when payroll for the period is under review" do
        period = create(:payroll_period, business: business, status: "under_review")
        adj = standalone_adjustment(period)
        expect(adj).not_to be_valid
        expect(adj.errors[:base])
          .to include(I18n.t("adjustments.errors.period_under_review"))
      end

      it "allows creation when the period is still draft" do
        period = create(:payroll_period, business: business, status: "draft")
        expect(standalone_adjustment(period)).to be_valid
      end

      it "allows creation when no payroll period exists yet for the month" do
        adj = build(:payroll_adjustment,
                    payroll_period: nil, business: business, user: employee,
                    created_by: create(:user, business: business),
                    period_month: 11, period_year: 2030)
        expect(adj).to be_valid
      end
    end
  end

  describe "#signed_amount" do
    it "returns positive amount for cash_incentive" do
      adjustment.adjustment_type = :cash_incentive
      adjustment.amount = 300.0
      expect(adjustment.signed_amount).to eq(300.0)
    end

    it "returns negative amount for manual_deduction" do
      adjustment.adjustment_type = :manual_deduction
      adjustment.amount = 200.0
      expect(adjustment.signed_amount).to eq(-200.0)
    end
  end

  describe "#line_item_type" do
    it "returns the current adjustment_type for normal records" do
      adjustment.adjustment_type = :cash_incentive
      expect(adjustment.line_item_type).to eq("cash_incentive")
    end

    it "returns commission unchanged" do
      adjustment.adjustment_type = :commission
      expect(adjustment.line_item_type).to eq("commission")
    end

    it "maps legacy 'bonus' to 'cash_incentive' via raw DB value" do
      # Simulate a DB row that predates the enum consolidation.
      # write_attribute bypasses the enum type-cast so the raw string is stored.
      adjustment.save!
      adjustment.class.where(id: adjustment.id).update_all(adjustment_type: "bonus")
      reloaded = PayrollAdjustment.find(adjustment.id)
      expect(reloaded.line_item_type).to eq("cash_incentive")
    end

    it "maps legacy 'reward' to 'cash_incentive'" do
      adjustment.save!
      adjustment.class.where(id: adjustment.id).update_all(adjustment_type: "reward")
      reloaded = PayrollAdjustment.find(adjustment.id)
      expect(reloaded.line_item_type).to eq("cash_incentive")
    end

    it "maps legacy 'eid_bonus' to 'cash_incentive'" do
      adjustment.save!
      adjustment.class.where(id: adjustment.id).update_all(adjustment_type: "eid_bonus")
      reloaded = PayrollAdjustment.find(adjustment.id)
      expect(reloaded.line_item_type).to eq("cash_incentive")
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:payroll_period).optional }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:created_by).class_name("User") }
  end
end
