require "rails_helper"

RSpec.describe Finance::EmployeeReconciliationSummarizer, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  let(:cash_pm) do
    PaymentMethod.create!(
      business:        business,
      name:            "Cash",
      settlement_type: "cash",
      active:          true
    )
  end

  def make_dr(opening_float_source_handover: nil, date: Date.current)
    DailyReconciliation.create!(
      branch:                       create(:branch, business: business),
      business:                     business,
      state:                        "closed",
      opened_at:                    1.hour.ago,
      closed_at:                    Time.current,
      business_date:                date,
      opening_float_source_handover: opening_float_source_handover
    )
  end

  def make_handover(dr:, from_user:, to_user: nil, self_deposit: false, accepted_at: Time.current, created_at: Time.current)
    TillHandover.create!(
      daily_reconciliation: dr,
      from_user:            from_user,
      to_user:              to_user,
      self_deposit:         self_deposit,
      accepted_at:          accepted_at,
      fresha_date:          dr.business_date,
      created_at:           created_at,
      updated_at:           created_at
    )
  end

  def add_amount(handover:, collected:, refund: 0, kind: "operational")
    TillHandoverAmount.create!(
      till_handover:       handover,
      payment_method:      cash_pm,
      payment_method_name: cash_pm.name,
      collected_amount:    collected,
      refund_amount:       refund,
      kind:                kind
    )
  end

  def summarize(dr)
    described_class.new(dr).summaries
  end

  def row_for(summaries, user)
    summaries.find { |s| s.user.id == user.id }
  end

  def cash_amount(summary_row)
    summary_row.amounts.find { |a| a.payment_method_id == cash_pm.id }
  end

  # ── Basic formula ────────────────────────────────────────────────────────────

  describe "net custody increase: last outgoing − sum(all incoming)" do
    context "single cashier, no opening float" do
      it "computes collected as closing amount minus nothing when no incoming" do
        eyad = create(:user, business: business)
        dr   = make_dr

        close = make_handover(dr: dr, from_user: eyad, self_deposit: true)
        add_amount(handover: close, collected: 5_000)

        result = summarize(dr)
        expect(row_for(result, eyad)).not_to be_nil
        expect(cash_amount(row_for(result, eyad)).collected_amount).to eq(5_000)
      end
    end

    context "cashier receives from another cashier, then closes" do
      it "subtracts incoming from closing amount" do
        eyad  = create(:user, business: business)
        islam = create(:user, business: business)
        dr    = make_dr

        t1 = 2.hours.ago
        t2 = 1.hour.ago

        h1 = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t1, created_at: t1)
        add_amount(handover: h1, collected: 8_035)

        close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t2, created_at: t2)
        add_amount(handover: close, collected: 11_590)

        result = summarize(dr)
        islam_row = row_for(result, islam)
        expect(cash_amount(islam_row).collected_amount).to eq(11_590 - 8_035)
      end
    end

    context "cashier with two custody periods (receives, hands off, receives again, closes)" do
      it "uses only the last outgoing and sums all incoming" do
        eyad  = create(:user, business: business)
        menna = create(:user, business: business)
        islam = create(:user, business: business)
        dr    = make_dr

        t1 = 4.hours.ago
        t2 = 3.hours.ago
        t3 = 2.hours.ago
        t4 = 1.hour.ago

        # Eyad → Islam (8,035)
        h1 = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t1, created_at: t1)
        add_amount(handover: h1, collected: 8_035)

        # Islam → Menna (10,220)
        h2 = make_handover(dr: dr, from_user: islam, to_user: menna, accepted_at: t2, created_at: t2)
        add_amount(handover: h2, collected: 10_220)

        # Menna → Islam (3,025)
        h3 = make_handover(dr: dr, from_user: menna, to_user: islam, accepted_at: t3, created_at: t3)
        add_amount(handover: h3, collected: 3_025)

        # Islam closes (11,590)
        close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t4, created_at: t4)
        add_amount(handover: close, collected: 11_590)

        result    = summarize(dr)
        islam_row = row_for(result, islam)

        # Formula: last outgoing (11,590) − sum(all incoming: 8,035 + 3,025) = 530
        expect(cash_amount(islam_row).collected_amount).to eq(530)
      end
    end
  end

  # ── Opening float: from another cashier ─────────────────────────────────────

  describe "opening float received from a different cashier" do
    it "includes the opening float in the incoming sum and deducts it from collected" do
      eyad  = create(:user, business: business)
      islam = create(:user, business: business)

      # Eyad seeded yesterday's opening float (source handover from a previous DR).
      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            eyad,
        to_user:              islam,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )

      # Today's DR: Eyad seeded the opening float, Islam receives it.
      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 3.hours.ago
      t2 = 1.hour.ago

      # Opening float receiving handover: from Eyad to Islam (operational, 1,000)
      of_recv = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 1_000)

      # Islam closes (8,000)
      close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t2, created_at: t2)
      add_amount(handover: close, collected: 8_000)

      result    = summarize(dr)
      islam_row = row_for(result, islam)

      # Opening float came from Eyad (different person) → included in incoming.
      # Collected = 8,000 − 1,000 = 7,000
      expect(cash_amount(islam_row).collected_amount).to eq(7_000)
    end
  end

  # ── Opening float: same cashier carrying forward from previous day ───────────

  describe "opening float originated by the same cashier (own carry-forward)" do
    it "excludes the own float from the incoming sum so it does not reduce collected" do
      islam = create(:user, business: business)

      # Islam was yesterday's final cashier and seeded the opening float.
      # The source handover's from_user is Islam himself.
      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            islam,
        to_user:              islam,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )

      # Today's DR: the opening float came from Islam himself.
      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 2.hours.ago
      t2 = 1.hour.ago

      # Opening float receiving handover: from Islam to Islam (own carry-forward).
      of_recv = make_handover(dr: dr, from_user: islam, to_user: islam, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 1_000)

      # Islam closes (8,000)
      close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t2, created_at: t2)
      add_amount(handover: close, collected: 8_000)

      result    = summarize(dr)
      islam_row = row_for(result, islam)

      # Own carry-forward float is excluded from incoming.
      # Collected = 8,000 − 0 = 8,000
      expect(cash_amount(islam_row).collected_amount).to eq(8_000)
    end

    it "still deducts handovers received from other cashiers even when own float is excluded" do
      eyad  = create(:user, business: business)
      islam = create(:user, business: business)

      # Islam seeded yesterday's float.
      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            islam,
        to_user:              islam,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )

      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 4.hours.ago
      t2 = 3.hours.ago
      t3 = 1.hour.ago

      # Own opening float (1,000) — excluded
      of_recv = make_handover(dr: dr, from_user: islam, to_user: islam, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 1_000)

      # Islam → Eyad (mid-day handoff), then Eyad → Islam (3,025) — included
      h2 = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t2, created_at: t2)
      add_amount(handover: h2, collected: 3_025)

      # Islam closes (11,590)
      close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t3, created_at: t3)
      add_amount(handover: close, collected: 11_590)

      result    = summarize(dr)
      islam_row = row_for(result, islam)

      # Own float (1,000) excluded; Eyad's handover (3,025) included.
      # Collected = 11,590 − 3,025 = 8,565
      expect(cash_amount(islam_row).collected_amount).to eq(8_565)
    end

    it "subtracts all handovers from other cashiers while skipping only the own carry-forward float" do
      eyad  = create(:user, business: business)
      menna = create(:user, business: business)
      islam = create(:user, business: business)

      # Islam seeded yesterday's float.
      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            islam,
        to_user:              islam,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )

      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 5.hours.ago
      t2 = 4.hours.ago
      t3 = 3.hours.ago
      t4 = 1.hour.ago

      # Own carry-forward (500) — excluded from incoming
      of_recv = make_handover(dr: dr, from_user: islam, to_user: islam, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 500)

      # Received from Eyad (8,035) — included
      h2 = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t2, created_at: t2)
      add_amount(handover: h2, collected: 8_035)

      # Received from Menna (3,025) — included
      h3 = make_handover(dr: dr, from_user: menna, to_user: islam, accepted_at: t3, created_at: t3)
      add_amount(handover: h3, collected: 3_025)

      # Islam closes (11,590)
      close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t4, created_at: t4)
      add_amount(handover: close, collected: 11_590)

      result    = summarize(dr)
      islam_row = row_for(result, islam)

      # Own float (500) excluded; Eyad (8,035) and Menna (3,025) both included.
      # Collected = 11,590 − 8,035 − 3,025 = 530
      expect(cash_amount(islam_row).collected_amount).to eq(530)
    end
  end
end
