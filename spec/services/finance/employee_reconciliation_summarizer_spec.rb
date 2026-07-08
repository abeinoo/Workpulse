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

  def make_handover(dr:, from_user:, to_user: nil, self_deposit: false, accepted_at: Time.current,
                    created_at: Time.current, opening_float_declaration: false)
    TillHandover.create!(
      daily_reconciliation:     dr,
      from_user:                from_user,
      to_user:                  to_user,
      self_deposit:             self_deposit,
      accepted_at:              accepted_at,
      fresha_date:              dr.business_date,
      opening_float_declaration: opening_float_declaration,
      created_at:               created_at,
      updated_at:               created_at
    )
  end

  def add_amount(handover:, collected:, refund: 0, kind: "operational", payment_method: nil)
    pm = payment_method || cash_pm
    TillHandoverAmount.create!(
      till_handover:       handover,
      payment_method:      pm,
      payment_method_name: pm.name,
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

  def add_adjustment(handover:, actor:, after_data:, reason_code: "wrong_amounts", created_at: Time.current)
    FinancialAdjustment.create!(
      adjustable:  handover,
      business:    business,
      actor:       actor,
      reason_code: reason_code,
      notes:       "Recount found a discrepancy at handover time",
      before_data: handover.amounts.map { |a|
        { payment_method_id: a.payment_method_id, collected_amount: a.collected_amount.to_s, refund_amount: a.refund_amount.to_s }
      },
      after_data:  after_data,
      created_at:  created_at
    )
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

    context "multiple cashiers hand off to the same closing cashier" do
      it "deducts all incoming handovers from different senders from the closing amount" do
        cashier_a = create(:user, business: business)
        cashier_b = create(:user, business: business)
        cashier_c = create(:user, business: business)
        dr        = make_dr

        t1 = 3.hours.ago
        t2 = 2.hours.ago
        t3 = 1.hour.ago

        # Cashier A → C (10)
        h_a = make_handover(dr: dr, from_user: cashier_a, to_user: cashier_c, accepted_at: t1, created_at: t1)
        add_amount(handover: h_a, collected: 10)

        # Cashier B → C (20)
        h_b = make_handover(dr: dr, from_user: cashier_b, to_user: cashier_c, accepted_at: t2, created_at: t2)
        add_amount(handover: h_b, collected: 20)

        # C closes (50)
        close = make_handover(dr: dr, from_user: cashier_c, self_deposit: true, accepted_at: t3, created_at: t3)
        add_amount(handover: close, collected: 50)

        result        = summarize(dr)
        cashier_c_row = row_for(result, cashier_c)

        # incoming = 10 + 20 = 30; last outgoing = 50
        # C collected = 50 − 30 = 20
        expect(cash_amount(cashier_c_row).collected_amount).to eq(20)
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

    it "excludes own carry-forward float while still deducting handovers from multiple senders" do
      cashier_a = create(:user, business: business)
      cashier_b = create(:user, business: business)
      cashier_c = create(:user, business: business)

      # C seeded yesterday's float — own carry-forward.
      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            cashier_c,
        to_user:              cashier_c,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )

      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 4.hours.ago
      t2 = 3.hours.ago
      t3 = 2.hours.ago
      t4 = 1.hour.ago

      # C's own carry-forward opening float (5) — excluded from incoming.
      of_recv = make_handover(dr: dr, from_user: cashier_c, to_user: cashier_c, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 5)

      # A → C (10) — included
      h_a = make_handover(dr: dr, from_user: cashier_a, to_user: cashier_c, accepted_at: t2, created_at: t2)
      add_amount(handover: h_a, collected: 10)

      # B → C (20) — included
      h_b = make_handover(dr: dr, from_user: cashier_b, to_user: cashier_c, accepted_at: t3, created_at: t3)
      add_amount(handover: h_b, collected: 20)

      # C closes (50)
      close = make_handover(dr: dr, from_user: cashier_c, self_deposit: true, accepted_at: t4, created_at: t4)
      add_amount(handover: close, collected: 50)

      result        = summarize(dr)
      cashier_c_row = row_for(result, cashier_c)

      # Own float (5) excluded; A (10) and B (20) both deducted.
      # Collected = 50 − 10 − 20 = 20
      expect(cash_amount(cashier_c_row).collected_amount).to eq(20)
    end
  end

  describe "opening float seeder credit: seeder passes float to another cashier (non-self-loop)" do
    # When the carry-forward float goes from the seeder to a DIFFERENT cashier,
    # the float's operational amounts travel through the custody chain and return to
    # the seeder embedded inside a later incoming handover from that other cashier.
    # Without the seeder credit, the full incoming amount (float + other cashier's
    # collections) is deducted, incorrectly reducing the seeder's net.
    # With the fix the of_recv amounts are subtracted from incoming_by_pm so the
    # float is restored to the seeder's collected total.

    it "credits the seeder's own float back when the seeder closes after receiving from the chain" do
      # Flow: A passes float(1,000) to B.  B collects 2,000.  B hands 3,000 to A.
      # A collects 3,500 more and closes with 6,500.
      # Expected A net = 1,000 (float) + 3,500 (personal) = 4,500.
      # Wrong (without fix): 6,500 − 3,000 = 3,500.
      cashier_a = create(:user, business: business)
      cashier_b = create(:user, business: business)

      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            cashier_a,
        to_user:              cashier_a,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )
      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 4.hours.ago
      t2 = 2.hours.ago
      t3 = 1.hour.ago

      # A passes float to B (non-self-loop: to_user=B, not A).
      of_recv = make_handover(dr: dr, from_user: cashier_a, to_user: cashier_b, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 1_000)

      # B collects 2,000 from customers, hands combined 3,000 back to A.
      h_b_to_a = make_handover(dr: dr, from_user: cashier_b, to_user: cashier_a, accepted_at: t2, created_at: t2)
      add_amount(handover: h_b_to_a, collected: 3_000)

      # A closes: 3,000 received + 3,500 personal = 6,500.
      close_a = make_handover(dr: dr, from_user: cashier_a, self_deposit: true, accepted_at: t3, created_at: t3)
      add_amount(handover: close_a, collected: 6_500)

      result        = summarize(dr)
      cashier_a_row = row_for(result, cashier_a)
      cashier_b_row = row_for(result, cashier_b)

      # A: float(1,000) credited back → net = 6,500 − (3,000 − 1,000) = 4,500
      expect(cash_amount(cashier_a_row).collected_amount).to eq(4_500),
        "seeder's own float (1,000) must be restored; expected 4,500, not 3,500"
      # B: last_outgoing=3,000 − incoming(float 1,000) = 2,000
      expect(cash_amount(cashier_b_row).collected_amount).to eq(2_000)
    end

    it "does NOT apply the seeder credit when the seeder's last_outgoing is the of_recv itself" do
      # Flow: A passes float(1,000) to B and has no further activity in this DR.
      # A's last_outgoing IS the of_recv handover → guard fires, no credit adjustment.
      # A's net = 1,000 (the float amount already captured in last_outgoing directly).
      cashier_a = create(:user, business: business)
      cashier_b = create(:user, business: business)

      source_handover = TillHandover.create!(
        daily_reconciliation: make_dr,
        from_user:            cashier_a,
        to_user:              cashier_a,
        self_deposit:         false,
        accepted_at:          1.day.ago,
        fresha_date:          Date.yesterday,
        created_at:           1.day.ago,
        updated_at:           1.day.ago
      )
      dr = make_dr(opening_float_source_handover: source_handover)

      t1 = 2.hours.ago
      t2 = 1.hour.ago

      # A → B: A's only outgoing, so last_outgoing == of_recv.
      of_recv = make_handover(dr: dr, from_user: cashier_a, to_user: cashier_b, accepted_at: t1, created_at: t1)
      add_amount(handover: of_recv, collected: 1_000)

      # B closes (3,000 = float + 2,000 personal).
      close_b = make_handover(dr: dr, from_user: cashier_b, self_deposit: true, accepted_at: t2, created_at: t2)
      add_amount(handover: close_b, collected: 3_000)

      result        = summarize(dr)
      cashier_a_row = row_for(result, cashier_a)
      cashier_b_row = row_for(result, cashier_b)

      # A: last_outgoing IS of_recv → no credit adjustment; net = 1,000.
      # If the adjustment fired incorrectly, A would show 1,000 − (−1,000) = 2,000.
      expect(cash_amount(cashier_a_row).collected_amount).to eq(1_000),
        "no seeder credit when last_outgoing is the of_recv handover itself"
      # B: 3,000 − 1,000 (received from A) = 2,000.
      expect(cash_amount(cashier_b_row).collected_amount).to eq(2_000)
    end
  end

  # ── Regression: single source of truth ──────────────────────────────────────
  #
  # All three surfaces that display cashier custody figures must derive from the
  # same algorithm and agree after persist! is called:
  #
  #   Surface 1 — Cashier Custody Summary        → summaries (live)
  #   Surface 2 — POS Transactions Verification  → :employee_summaries local
  #                                                 (same live summaries, passed from controller)
  #   Surface 3 — DB snapshot / exports          → employee_reconciliation_summaries rows
  #                                                 written by persist!
  #
  # Asserting that summaries == persist! output proves all three agree, because both
  # UI sections now read exclusively from live summaries, and persist! feeds the
  # same aggregate_by_employee formula into the snapshot.
  #
  # If someone changes a view to re-introduce a private DB query, or changes
  # aggregate_by_employee without updating persist!, this spec will catch it.

  # ── Regression: Opening Float Left must not shadow Day Closed ────────────────
  #
  # Production bug (DR 16, 2026-07-05): a cashier who closes the day and then
  # immediately leaves an opening float for the next DR ends up with TWO
  # self_deposit handovers in created_at order:
  #
  #   1. Day Closed (#66)       — kind: operational  → the custody source
  #   2. Opening Float Left (#67) — kind: next_day    → next-day declaration only
  #
  # The old code used outgoing_list.last, which picked #67.  Since #67 has no
  # operational amounts the algorithm produced collected = 0.00 instead of the
  # correct 2,820 (Cash) and 1,113 (Visa).
  #
  # The fix excludes opening_float_declaration handovers from outgoing_by_user so
  # they can never be selected as last_outgoing.

  describe "Opening Float Left handover does not shadow Day Closed" do
    let(:visa_pm) do
      PaymentMethod.create!(
        business:        business,
        name:            "Visa",
        settlement_type: "card",
        active:          true
      )
    end

    it "selects Day Closed as last_outgoing when Opening Float Left was created after it" do
      abu_khalaf = create(:user, business: business)
      menna      = create(:user, business: business)
      eyad       = create(:user, business: business)
      dr         = make_dr

      t1 = 4.hours.ago
      t2 = 3.hours.ago
      t3 = 2.hours.ago   # Day Closed
      t4 = 1.hour.ago    # Opening Float Left — created AFTER day close

      # Abu Khalaf → Eyad  (Cash=6,460 Visa=3,427)
      h_ak = make_handover(dr: dr, from_user: abu_khalaf, to_user: eyad, accepted_at: t1, created_at: t1)
      add_amount(handover: h_ak, collected: 6_460)
      add_amount(handover: h_ak, collected: 3_427, payment_method: visa_pm)

      # Menna → Eyad  (Cash=3,790 Visa=0)
      h_mn = make_handover(dr: dr, from_user: menna, to_user: eyad, accepted_at: t2, created_at: t2)
      add_amount(handover: h_mn, collected: 3_790)
      add_amount(handover: h_mn, collected: 0, payment_method: visa_pm)

      # Eyad closes the day  — operational amounts
      close = make_handover(dr: dr, from_user: eyad, self_deposit: true, accepted_at: nil, created_at: t3)
      add_amount(handover: close, collected: 13_070)
      add_amount(handover: close, collected: 4_540, payment_method: visa_pm)

      # Eyad leaves Opening Float for next day — next_day amounts only, created after close
      ofl = make_handover(dr: dr, from_user: eyad, self_deposit: true, accepted_at: nil,
                          created_at: t4, opening_float_declaration: true)
      add_amount(handover: ofl, collected: 840, kind: "next_day")

      result   = summarize(dr)
      eyad_row = row_for(result, eyad)

      # Cash: 13,070 − (6,460 + 3,790) = 2,820
      expect(cash_amount(eyad_row).collected_amount).to eq(2_820),
        "Cash collected: expected 2,820, got #{cash_amount(eyad_row).collected_amount}"

      # Visa: 4,540 − (3,427 + 0) = 1,113
      visa_amt = eyad_row.amounts.find { |a| a.payment_method_id == visa_pm.id }
      expect(visa_amt.collected_amount).to eq(1_113),
        "Visa collected: expected 1,113, got #{visa_amt.collected_amount}"
    end
  end

  # ── Regression: single source of truth ──────────────────────────────────────
  #
  # All three surfaces that display cashier custody figures must derive from the
  # same algorithm and agree after persist! is called:
  #
  #   Surface 1 — Cashier Custody Summary        → summaries (live)
  #   Surface 2 — POS Transactions Verification  → :employee_summaries local
  #                                                 (same live summaries, passed from controller)
  #   Surface 3 — DB snapshot / exports          → employee_reconciliation_summaries rows
  #                                                 written by persist!
  #
  # Asserting that summaries == persist! output proves all three agree, because both
  # UI sections now read exclusively from live summaries, and persist! feeds the
  # same aggregate_by_employee formula into the snapshot.
  #
  # If someone changes a view to re-introduce a private DB query, or changes
  # aggregate_by_employee without updating persist!, this spec will catch it.

  describe "single source of truth: persist! snapshot and live summaries always agree" do
    it "produces identical per-cashier, per-payment-method figures for every user" do
      eyad  = create(:user, business: business)
      menna = create(:user, business: business)
      islam = create(:user, business: business)
      dr    = make_dr

      t1 = 4.hours.ago
      t2 = 3.hours.ago
      t3 = 2.hours.ago
      t4 = 1.hour.ago

      # Eyad → Islam  (8,035 collected, 200 refunds)
      h1 = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t1, created_at: t1)
      add_amount(handover: h1, collected: 8_035, refund: 200)

      # Islam → Menna mid-day  (10,220 collected, 350 refunds)
      h2 = make_handover(dr: dr, from_user: islam, to_user: menna, accepted_at: t2, created_at: t2)
      add_amount(handover: h2, collected: 10_220, refund: 350)

      # Menna → Islam  (3,025 collected, 100 refunds)
      h3 = make_handover(dr: dr, from_user: menna, to_user: islam, accepted_at: t3, created_at: t3)
      add_amount(handover: h3, collected: 3_025, refund: 100)

      # Islam closes  (11,590 collected, 420 refunds)
      close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t4, created_at: t4)
      add_amount(handover: close, collected: 11_590, refund: 420)

      # Write the DB snapshot through the same service.
      described_class.new(dr).persist!

      live_rows = described_class.new(dr).summaries
      db_rows   = dr.employee_reconciliation_summaries
                    .includes(:user, amounts: :payment_method)
      db_by_uid = db_rows.index_by(&:user_id)

      # ── Assert correct values for Islam (the multi-period cashier) ────────
      #
      # Formula: last_outgoing.operational − sum(all_incoming.operational)
      #   collected: 11,590 − (8,035 + 3,025) = 530
      #   refund:       420 − (  200 +   100) = 120
      #
      # Both surfaces must produce these numbers, not the old per-period result.
      islam_live = row_for(live_rows, islam)
      expect(cash_amount(islam_live).collected_amount).to eq(530),
        "Islam collected: expected 530, got #{cash_amount(islam_live).collected_amount}"
      expect(cash_amount(islam_live).refund_amount).to eq(120),
        "Islam refund: expected 120, got #{cash_amount(islam_live).refund_amount}"

      # ── Assert live summaries == DB snapshot for every cashier/PM pair ───
      expect(live_rows.size).to eq(db_rows.size),
        "live has #{live_rows.size} cashier row(s), snapshot has #{db_rows.size}"

      live_rows.each do |live|
        db = db_by_uid[live.user.id]

        expect(db).not_to be_nil,
          "#{live.user.full_name}: present in live summaries but absent from DB snapshot"

        live.amounts.each do |la|
          da = db.amounts.find { |a| a.payment_method_id == la.payment_method_id }

          expect(da).not_to be_nil,
            "#{live.user.full_name} #{la.payment_method_name}: " \
            "present in live summaries but absent from DB snapshot"

          expect(da.collected_amount.to_d).to eq(la.collected_amount),
            "#{live.user.full_name} #{la.payment_method_name} collected: " \
            "live=#{la.collected_amount} snapshot=#{da.collected_amount}"

          expect(da.refund_amount.to_d).to eq(la.refund_amount),
            "#{live.user.full_name} #{la.payment_method_name} refund: " \
            "live=#{la.refund_amount} snapshot=#{da.refund_amount}"
        end

        # No extra rows in the snapshot that are absent from live.
        db.amounts.each do |da|
          pm_ids = live.amounts.map(&:payment_method_id)
          expect(pm_ids).to include(da.payment_method_id),
            "#{live.user.full_name}: pm_id #{da.payment_method_id} in DB snapshot " \
            "but absent from live summaries"
        end
      end
    end
  end

  # ── End-to-end regression: full production custody flow ──────────────────────
  #
  # Reproduces the exact real production scenario that triggered the bug
  # (DR 16, 2026-07-05) at the service layer:
  #
  #   1. Cashier A (previous DR) leaves opening float → opening_float_declaration: true
  #   2. Cashier B receives the opening float from A (regular incoming handover)
  #   3. Cashier C hands cash to B
  #   4. Cashier D hands cash to B
  #   5. B closes the business day   ← Day Closed, operational amounts
  #   6. B leaves opening float for the next DR ← Opening Float Left, next_day only,
  #                                                created AFTER Day Closed
  #
  # The fix must guarantee that step 6 never shadows step 5 as last_outgoing.
  #
  # All four data surfaces must agree:
  #   • Cashier Custody Summary   → live summaries
  #   • POS Verification section  → same live summaries (passed as local by controller)
  #   • DB snapshot               → employee_reconciliation_summaries via persist!
  #   • Audit Timeline            → unchanged (driven by opening_float_declaration? flag)
  #   • Next-day float            → OFL next_day amounts untouched by the summarizer

  describe "end-to-end: full production custody flow with Opening Float Left after Day Closed" do
    let(:visa_pm) do
      PaymentMethod.create!(
        business:        business,
        name:            "Visa",
        settlement_type: "card",
        active:          true
      )
    end

    it "selects Day Closed as last_outgoing and matches live, snapshot, and flag invariants" do
      cashier_a = create(:user, business: business)
      cashier_b = create(:user, business: business)
      cashier_c = create(:user, business: business)
      cashier_d = create(:user, business: business)

      # ── Step 1: previous DR — Cashier A leaves opening float ─────────────
      prev_dr = make_dr(date: Date.current - 1)

      ofl_a = make_handover(
        dr:                        prev_dr,
        from_user:                 cashier_a,
        self_deposit:              true,
        accepted_at:               nil,
        opening_float_declaration: true,
        created_at:                25.hours.ago
      )
      # A declares Cash=500, Visa=200 for the next day.
      add_amount(handover: ofl_a, collected: 500, kind: "next_day")
      add_amount(handover: ofl_a, collected: 200, kind: "next_day", payment_method: visa_pm)

      # ── Today's DR: seeded from A's opening float declaration ─────────────
      today_dr = make_dr(opening_float_source_handover: ofl_a)

      t1 = 5.hours.ago   # B receives opening float from A
      t2 = 4.hours.ago   # C → B
      t3 = 3.hours.ago   # D → B
      t4 = 2.hours.ago   # B closes (Day Closed)
      t5 = 1.hour.ago    # B leaves opening float for next day (AFTER Day Closed)

      # ── Step 2: B receives opening float from A ───────────────────────────
      # A's of_seeder_id ≠ B → opening float is NOT own-carry-forward for B
      # → it IS included in B's incoming sum (no exclusion).
      of_recv = make_handover(
        dr: today_dr, from_user: cashier_a, to_user: cashier_b,
        accepted_at: t1, created_at: t1
      )
      add_amount(handover: of_recv, collected: 500)
      add_amount(handover: of_recv, collected: 200, payment_method: visa_pm)

      # ── Step 3: C → B (Cash only) ─────────────────────────────────────────
      h_c = make_handover(
        dr: today_dr, from_user: cashier_c, to_user: cashier_b,
        accepted_at: t2, created_at: t2
      )
      add_amount(handover: h_c, collected: 3_000)

      # ── Step 4: D → B (Cash only) ─────────────────────────────────────────
      h_d = make_handover(
        dr: today_dr, from_user: cashier_d, to_user: cashier_b,
        accepted_at: t3, created_at: t3
      )
      add_amount(handover: h_d, collected: 2_000)

      # ── Step 5: B closes the day (Day Closed — operational amounts) ───────
      day_close = make_handover(
        dr: today_dr, from_user: cashier_b, self_deposit: true,
        accepted_at: nil, created_at: t4
      )
      add_amount(handover: day_close, collected: 8_500)
      add_amount(handover: day_close, collected: 900, payment_method: visa_pm)

      # ── Step 6: B leaves opening float for next day — AFTER Day Closed ────
      # next_day amounts only; opening_float_declaration: true.
      # This is the handover that caused the production bug when picked as last_outgoing.
      ofl_b = make_handover(
        dr: today_dr, from_user: cashier_b, self_deposit: true,
        accepted_at: nil, created_at: t5, opening_float_declaration: true
      )
      add_amount(handover: ofl_b, collected: 400, kind: "next_day")

      # ── Persist snapshot ──────────────────────────────────────────────────
      described_class.new(today_dr).persist!

      # ── Surface 1 & 2: Cashier Custody Summary and POS Verification ───────
      # Both sections read from the same `summaries` call in the controller.
      # A correct live result here proves both UI surfaces are correct.
      live_rows = described_class.new(today_dr).summaries
      b_live    = row_for(live_rows, cashier_b)

      # B's incoming: OF from A (Cash=500, Visa=200) + C (Cash=3,000) + D (Cash=2,000)
      # last_outgoing: Day Closed (Cash=8,500, Visa=900) — NOT Opening Float Left
      # B collected Cash = 8,500 − (500 + 3,000 + 2,000) = 3,000
      # B collected Visa = 900   − 200                   = 700
      b_live_cash = cash_amount(b_live)
      b_live_visa = b_live.amounts.find { |a| a.payment_method_id == visa_pm.id }

      expect(b_live_cash.collected_amount).to eq(3_000),
        "Cash collected: expected 3,000, got #{b_live_cash.collected_amount}"
      expect(b_live_visa.collected_amount).to eq(700),
        "Visa collected: expected 700, got #{b_live_visa.collected_amount}"

      # ── Surface 3: DB snapshot matches live ───────────────────────────────
      db_rows   = today_dr.employee_reconciliation_summaries.includes(:user, amounts: :payment_method)
      db_by_uid = db_rows.index_by(&:user_id)
      b_db      = db_by_uid[cashier_b.id]

      expect(b_db).not_to be_nil, "B must have a DB snapshot row after persist!"

      b_db_cash = b_db.amounts.find { |a| a.payment_method_id == cash_pm.id }
      b_db_visa = b_db.amounts.find { |a| a.payment_method_id == visa_pm.id }

      expect(b_db_cash.collected_amount.to_d).to eq(3_000),
        "DB snapshot Cash: expected 3,000, got #{b_db_cash.collected_amount}"
      expect(b_db_visa.collected_amount.to_d).to eq(700),
        "DB snapshot Visa: expected 700, got #{b_db_visa.collected_amount}"

      # ── Surface 4: Audit Timeline flag invariants ─────────────────────────
      # The timeline builder uses opening_float_declaration? to distinguish
      # :day_closed from :opening_float_left.  Asserting the flags here proves
      # the timeline event classification is correct without invoking the controller.
      expect(day_close.opening_float_declaration?).to be(false),
        "Day Closed handover must NOT carry opening_float_declaration"
      expect(ofl_b.opening_float_declaration?).to be(true),
        "Opening Float Left handover MUST carry opening_float_declaration"

      # ── Surface 5: next-day float amounts are untouched ───────────────────
      # The summarizer must leave ofl_b's next_day amounts intact so the next
      # DR's opening float setup can consume them normally.
      ofl_b_next_day = ofl_b.amounts.reload.select { |a| a.kind == "next_day" }

      expect(ofl_b_next_day.size).to eq(1),
        "OFL handover must still have exactly 1 next_day amount after persist! ran"
      expect(ofl_b_next_day.first.collected_amount).to eq(400),
        "OFL next_day Cash must be 400 — the summarizer must not modify it"

      # ── Own-carry-forward exclusion does NOT fire for B ───────────────────
      # A seeded the opening float (of_seeder_id = A ≠ B), so the OF receiving
      # handover is correctly included in B's incoming sum.  Verify indirectly:
      # if the exclusion had incorrectly fired, Cash would be 3,500 (not 3,000).
      expect(b_live_cash.collected_amount).not_to eq(3_500),
        "Own-carry-forward exclusion must NOT fire when seeder (A) ≠ receiver (B)"
    end
  end

  # ── FinancialAdjustment makes the corrected amount effective immediately ─────
  #
  # Reproduces the reported gap: A hands over to Hossam (peer handover, DR still
  # open, no day close yet). A's Custody Summary row is computed from that
  # handover as last_outgoing. A manager then records a documentary
  # Finance::TillHandoverAdjuster correction on that same handover. Both the
  # Cashier Custody Summary and POS Verification (same @employee_summaries) must
  # reflect the corrected amount immediately — without the original
  # TillHandoverAmount ever being mutated.

  describe "FinancialAdjustment on an accepted, not-yet-closed handover" do
    it "is reflected immediately in the sender's live custody row, leaving the original amount untouched" do
      a      = create(:user, business: business)
      hossam = create(:user, business: business)
      dr     = make_dr

      h1 = make_handover(dr: dr, from_user: a, to_user: hossam, accepted_at: 1.hour.ago, created_at: 1.hour.ago)
      original_amount = add_amount(handover: h1, collected: 370)

      add_adjustment(
        handover:   h1,
        actor:      a,
        after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ]
      )

      a_row = row_for(summarize(dr), a)
      expect(cash_amount(a_row).collected_amount).to eq(470)

      # The original historical record is never mutated by an adjustment.
      expect(original_amount.reload.collected_amount).to eq(370)
    end

    it "deducts the adjusted (not original) amount from the receiver's incoming sum" do
      a      = create(:user, business: business)
      hossam = create(:user, business: business)
      dr     = make_dr

      h1 = make_handover(dr: dr, from_user: a, to_user: hossam, accepted_at: 2.hours.ago, created_at: 2.hours.ago)
      add_amount(handover: h1, collected: 370)
      add_adjustment(
        handover:   h1,
        actor:      a,
        after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ]
      )

      close = make_handover(dr: dr, from_user: hossam, self_deposit: true, accepted_at: 1.hour.ago, created_at: 1.hour.ago)
      add_amount(handover: close, collected: 470)

      hossam_row = row_for(summarize(dr), hossam)
      # last_outgoing (470) − incoming (adjusted: 470, not the original 370) = 0
      expect(cash_amount(hossam_row).collected_amount).to eq(0)
    end

    it "lets a later adjustment supersede an earlier one for the same handover" do
      a      = create(:user, business: business)
      hossam = create(:user, business: business)
      dr     = make_dr

      h1 = make_handover(dr: dr, from_user: a, to_user: hossam, accepted_at: 2.hours.ago, created_at: 2.hours.ago)
      add_amount(handover: h1, collected: 370)
      add_adjustment(handover: h1, actor: a,
                     after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ],
                     created_at: 1.hour.ago)
      add_adjustment(handover: h1, actor: a,
                     after_data: [ { payment_method_id: cash_pm.id, collected_amount: "490", refund_amount: "0" } ],
                     created_at: 30.minutes.ago)

      a_row = row_for(summarize(dr), a)
      expect(cash_amount(a_row).collected_amount).to eq(490)
    end
  end
end
