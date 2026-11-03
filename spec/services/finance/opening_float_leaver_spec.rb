require "rails_helper"

RSpec.describe Finance::OpeningFloatLeaver, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:today)    { BusinessDay.current(context: business) }

  let(:cashier) do
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[close_till_session])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def closed_dr(date, closed_at: Time.current)
    DailyReconciliation.create_for!(branch: branch, business_date: date).tap do |dr|
      dr.update!(state: "closed", closed_at: closed_at)
    end
  end

  def leave(dr)
    described_class.new(actor: cashier, daily_reconciliation_id: dr.id,
                        amounts: { cash_pm.id.to_s => { collected_amount: "300", refund_amount: "0" } }).call
  end

  it "leaves a float from today's closed DR, preparing tomorrow's waiting DR" do
    result = leave(closed_dr(today))

    expect(result.ok?).to be true
    expect(result.daily_reconciliation).to be_waiting_for_opening
    expect(result.daily_reconciliation.business_date).to eq(today + 1)
  end

  describe "the current-business-day restriction (server-side, not only the hidden button)" do
    it "refuses a closed past-dated DR and writes nothing" do
      past = closed_dr(today - 2.days)

      result = nil
      expect { result = leave(past) }.not_to change(TillHandover, :count)

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("opening_floats.errors.not_current_business_day"))
      expect(DailyReconciliation.waiting_for(branch)).to be_nil
      expect(AuditLog.where(action: "opening_float_prepared")).to be_empty
    end

    it "refuses yesterday's DR closed late, after the business day rolled over" do
      result = leave(closed_dr(today - 1.day))

      expect(result.error).to eq(I18n.t("opening_floats.errors.not_current_business_day"))
    end
  end

  it "refuses while another DR at the branch is open (a past date opened after today closed)" do
    today_dr = closed_dr(today)
    past_dr  = Finance::HistoricalDailyReconciliationCreator.new(branch: branch, business_date: today - 3.days,
                                                                  actor: cashier).call.reconciliation

    result = nil
    expect { result = leave(today_dr) }.not_to change(TillHandover, :count)

    expect(result.error).to eq(I18n.t("opening_floats.errors.another_day_open",
                                      date: I18n.l(past_dr.business_date, format: :long)))
    expect(DailyReconciliation.waiting_for(branch)).to be_nil
  end

  it "refuses a second float from the same DR" do
    dr = closed_dr(today)
    leave(dr)

    expect(leave(dr).error).to eq(I18n.t("opening_floats.errors.already_prepared"))
    expect(dr.till_handovers.where(opening_float_declaration: true).count).to eq(1)
  end
end
