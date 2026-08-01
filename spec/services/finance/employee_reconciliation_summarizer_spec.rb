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

  let(:visa_pm) do
    PaymentMethod.create!(
      business:        business,
      name:            "Visa",
      settlement_type: "card",
      active:          true
    )
  end

  def make_dr(date: Date.current)
    DailyReconciliation.create!(
      branch:        create(:branch, business: business),
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: date
    )
  end

  def make_handover(dr:, from_user:, to_user: nil, self_deposit: false, accepted_at: Time.current,
                    created_at: Time.current, opening_float_declaration: false)
    TillHandover.create!(
      daily_reconciliation:      dr,
      from_user:                 from_user,
      to_user:                   to_user,
      self_deposit:              self_deposit,
      accepted_at:               accepted_at,
      fresha_date:               dr.business_date,
      opening_float_declaration: opening_float_declaration,
      created_at:                created_at,
      updated_at:                created_at
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

  def amount_for(summary_row, pm)
    summary_row.amounts.find { |a| a.payment_method_id == pm.id }
  end

  def cash_amount(summary_row)
    amount_for(summary_row, cash_pm)
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

  # ── Business rule ──────────────────────────────────────────────────────────
  #
  # For every employee, the day splits into custody periods. Each period ends
  # in one of the employee's own outgoing operational handovers (peer handover
  # or self-deposit/day-close). A period's contribution is that outgoing
  # amount minus whatever the employee received (as to_user on an accepted
  # handover) since their previous outgoing handover, or since the start of
  # the DR for their first period. The employee's total is the sum of every
  # period's contribution. opening_float_declaration? handovers are not a
  # custody event and never start or end a period.

  # ── Case 1: Abdelrahman — two periods, neither with any incoming ────────────

  describe "Case 1: employee hands over the opening float, then later hands over again with no receive event" do
    it "sums both periods in full — an empty incoming window is not a special case" do
      employee = create(:user, business: business)
      dr       = make_dr

      t1 = 2.hours.ago
      t2 = 1.hour.ago

      # Period 1: opening float handover. Nothing preceded it.
      float_handover = make_handover(dr: dr, from_user: employee, to_user: create(:user, business: business),
                                     accepted_at: t1, created_at: t1)
      add_amount(handover: float_handover, collected: 680)
      add_amount(handover: float_handover, collected: 1_697, payment_method: visa_pm)

      # Period 2: a later handover, no receive event re-establishing custody in between.
      later_handover = make_handover(dr: dr, from_user: employee, self_deposit: true,
                                     accepted_at: t2, created_at: t2)
      add_amount(handover: later_handover, collected: 1_020)
      add_amount(handover: later_handover, collected: 755, payment_method: visa_pm)

      result = summarize(dr)
      row    = row_for(result, employee)

      expect(cash_amount(row).collected_amount).to eq(1_700)
      expect(amount_for(row, visa_pm).collected_amount).to eq(2_452)
    end
  end

  # ── Case 2: Aya — opening float receive belongs to her first period ─────────

  describe "Case 2: employee receives the opening float, then hands over once" do
    it "subtracts the received float from the single period's outgoing amount" do
      seeder   = create(:user, business: business)
      employee = create(:user, business: business)
      dr       = make_dr

      t1 = 2.hours.ago
      t2 = 1.hour.ago

      # Incoming: opening float receive.
      float_recv = make_handover(dr: dr, from_user: seeder, to_user: employee, accepted_at: t1, created_at: t1)
      add_amount(handover: float_recv, collected: 680)
      add_amount(handover: float_recv, collected: 1_697, payment_method: visa_pm)

      # Outgoing: the employee's only period, ending here.
      close = make_handover(dr: dr, from_user: employee, self_deposit: true, accepted_at: t2, created_at: t2)
      add_amount(handover: close, collected: 3_190)
      add_amount(handover: close, collected: 2_967, payment_method: visa_pm)

      result = summarize(dr)
      row    = row_for(result, employee)

      expect(cash_amount(row).collected_amount).to eq(2_510)
      expect(amount_for(row, visa_pm).collected_amount).to eq(1_270)

      # The seeder is credited for handing the float over — it's not double-counted.
      seeder_row = row_for(result, seeder)
      expect(cash_amount(seeder_row).collected_amount).to eq(680)
      expect(amount_for(seeder_row, visa_pm).collected_amount).to eq(1_697)
    end
  end

  # ── Case 3: single custody period, no incoming ───────────────────────────────

  describe "Case 3: single custody period with no incoming" do
    it "equals the full outgoing amount" do
      employee = create(:user, business: business)
      dr       = make_dr

      close = make_handover(dr: dr, from_user: employee, self_deposit: true)
      add_amount(handover: close, collected: 5_000)
      add_amount(handover: close, collected: 2_500, payment_method: visa_pm)

      row = row_for(summarize(dr), employee)

      expect(cash_amount(row).collected_amount).to eq(5_000)
      expect(amount_for(row, visa_pm).collected_amount).to eq(2_500)
    end
  end

  # ── Case 4: multiple custody periods, multiple incoming per period ──────────

  describe "Case 4: multiple custody periods, each with its own incoming handovers" do
    it "subtracts only the incoming events belonging to each period's own window" do
      a = create(:user, business: business)
      b = create(:user, business: business)
      c = create(:user, business: business)
      d = create(:user, business: business)
      dr = make_dr

      t1 = 6.hours.ago  # B → A
      t2 = 5.hours.ago  # A → C   (A's period 1 ends)
      t3 = 4.hours.ago  # C → A
      t4 = 3.hours.ago  # A → D   (A's period 2 ends)
      t5 = 2.hours.ago  # D → A
      t6 = 1.hour.ago   # A closes (A's period 3 ends)

      h1 = make_handover(dr: dr, from_user: b, to_user: a, accepted_at: t1, created_at: t1)
      add_amount(handover: h1, collected: 700)
      add_amount(handover: h1, collected: 400, payment_method: visa_pm)

      h2 = make_handover(dr: dr, from_user: a, to_user: c, accepted_at: t2, created_at: t2)
      add_amount(handover: h2, collected: 850)
      add_amount(handover: h2, collected: 480, payment_method: visa_pm)

      h3 = make_handover(dr: dr, from_user: c, to_user: a, accepted_at: t3, created_at: t3)
      add_amount(handover: h3, collected: 1_100)
      add_amount(handover: h3, collected: 600, payment_method: visa_pm)

      h4 = make_handover(dr: dr, from_user: a, to_user: d, accepted_at: t4, created_at: t4)
      add_amount(handover: h4, collected: 1_400)
      add_amount(handover: h4, collected: 800, payment_method: visa_pm)

      h5 = make_handover(dr: dr, from_user: d, to_user: a, accepted_at: t5, created_at: t5)
      add_amount(handover: h5, collected: 1_500)
      add_amount(handover: h5, collected: 850, payment_method: visa_pm)

      close = make_handover(dr: dr, from_user: a, self_deposit: true, accepted_at: t6, created_at: t6)
      add_amount(handover: close, collected: 1_620)
      add_amount(handover: close, collected: 920, payment_method: visa_pm)

      a_row = row_for(summarize(dr), a)

      # Period 1: 850 - 700 = 150 | Period 2: 1400 - 1100 = 300 | Period 3: 1620 - 1500 = 120
      # Total cash: 150 + 300 + 120 = 570
      expect(cash_amount(a_row).collected_amount).to eq(570)
      # Period 1: 480 - 400 = 80 | Period 2: 800 - 600 = 200 | Period 3: 920 - 850 = 70
      # Total visa: 80 + 200 + 70 = 350
      expect(amount_for(a_row, visa_pm).collected_amount).to eq(350)

      # Conservation check: every employee's total sums to the final till count.
      result = summarize(dr)
      b_row  = row_for(result, b)
      c_row  = row_for(result, c)
      d_row  = row_for(result, d)

      total_cash = cash_amount(a_row).collected_amount + cash_amount(b_row).collected_amount +
                   cash_amount(c_row).collected_amount + cash_amount(d_row).collected_amount
      total_visa = amount_for(a_row, visa_pm).collected_amount + amount_for(b_row, visa_pm).collected_amount +
                   amount_for(c_row, visa_pm).collected_amount + amount_for(d_row, visa_pm).collected_amount

      expect(total_cash).to eq(1_620)
      expect(total_visa).to eq(920)
    end
  end

  # ── Regression: exact production scenario (DR #93, 2026-07-30) ──────────────

  describe "production regression: DR #93" do
    it "matches Abdelrahman (seeder, two periods) and Aya (receiver, one period) simultaneously" do
      abdelrahman = create(:user, business: business)
      aya         = create(:user, business: business)
      menna       = create(:user, business: business)
      dr          = make_dr

      t1 = 3.hours.ago
      t2 = 2.hours.ago
      t3 = 1.hour.ago

      # Abdelrahman → Aya (opening float) — Abdelrahman's period 1.
      float_handover = make_handover(dr: dr, from_user: abdelrahman, to_user: aya, accepted_at: t1, created_at: t1)
      add_amount(handover: float_handover, collected: 680)
      add_amount(handover: float_handover, collected: 1_697, payment_method: visa_pm)

      # Aya → Menna — Aya's only period, nets the float she received.
      aya_close = make_handover(dr: dr, from_user: aya, to_user: menna, accepted_at: t2, created_at: t2)
      add_amount(handover: aya_close, collected: 3_190)
      add_amount(handover: aya_close, collected: 2_967, payment_method: visa_pm)

      # Abdelrahman → Menna — Abdelrahman's period 2, no receive event in between.
      abdelrahman_close = make_handover(dr: dr, from_user: abdelrahman, to_user: menna, accepted_at: t3, created_at: t3)
      add_amount(handover: abdelrahman_close, collected: 1_020)
      add_amount(handover: abdelrahman_close, collected: 755, payment_method: visa_pm)

      result      = summarize(dr)
      abd_row     = row_for(result, abdelrahman)
      aya_row     = row_for(result, aya)

      expect(cash_amount(abd_row).collected_amount).to eq(1_700)
      expect(amount_for(abd_row, visa_pm).collected_amount).to eq(2_452)

      expect(cash_amount(aya_row).collected_amount).to eq(2_510)
      expect(amount_for(aya_row, visa_pm).collected_amount).to eq(1_270)
    end
  end

  # ── opening_float_declaration? handovers are not a custody event ────────────

  describe "Opening Float Left (declaration) handovers never start or end a period" do
    it "contributes nothing and does not split the employee's periods" do
      employee = create(:user, business: business)
      dr       = make_dr

      t1 = 2.hours.ago
      t2 = 1.hour.ago

      close = make_handover(dr: dr, from_user: employee, self_deposit: true, accepted_at: nil, created_at: t1)
      add_amount(handover: close, collected: 13_070)
      add_amount(handover: close, collected: 4_540, payment_method: visa_pm)

      # Declared after close — must not count, and must not create a phantom period.
      ofl = make_handover(dr: dr, from_user: employee, self_deposit: true, accepted_at: nil,
                          created_at: t2, opening_float_declaration: true)
      add_amount(handover: ofl, collected: 840, kind: "next_day")

      row = row_for(summarize(dr), employee)

      expect(cash_amount(row).collected_amount).to eq(13_070)
      expect(amount_for(row, visa_pm).collected_amount).to eq(4_540)
    end
  end

  # ── Regression: single source of truth ──────────────────────────────────────

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

      h1 = make_handover(dr: dr, from_user: eyad, to_user: islam, accepted_at: t1, created_at: t1)
      add_amount(handover: h1, collected: 8_035, refund: 200)

      h2 = make_handover(dr: dr, from_user: islam, to_user: menna, accepted_at: t2, created_at: t2)
      add_amount(handover: h2, collected: 10_220, refund: 350)

      h3 = make_handover(dr: dr, from_user: menna, to_user: islam, accepted_at: t3, created_at: t3)
      add_amount(handover: h3, collected: 3_025, refund: 100)

      close = make_handover(dr: dr, from_user: islam, self_deposit: true, accepted_at: t4, created_at: t4)
      add_amount(handover: close, collected: 11_590, refund: 420)

      described_class.new(dr).persist!

      live_rows = described_class.new(dr).summaries
      db_rows   = dr.employee_reconciliation_summaries
                    .includes(:user, amounts: :payment_method)
      db_by_uid = db_rows.index_by(&:user_id)

      # Islam: period 1 (h2: 10,220 - 8,035 received from eyad = 2,185),
      #        period 2 (close: 11,590 - 3,025 received from menna = 8,565)
      # Total: 2,185 + 8,565 = 10,750. Refund: (350-200) + (420-100) = 150+320=470.
      islam_live = row_for(live_rows, islam)
      expect(cash_amount(islam_live).collected_amount).to eq(10_750),
        "Islam collected: expected 10,750, got #{cash_amount(islam_live).collected_amount}"
      expect(cash_amount(islam_live).refund_amount).to eq(470),
        "Islam refund: expected 470, got #{cash_amount(islam_live).refund_amount}"

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

        db.amounts.each do |da|
          pm_ids = live.amounts.map(&:payment_method_id)
          expect(pm_ids).to include(da.payment_method_id),
            "#{live.user.full_name}: pm_id #{da.payment_method_id} in DB snapshot " \
            "but absent from live summaries"
        end
      end
    end
  end

  # ── FinancialAdjustment makes the corrected amount effective immediately ─────

  describe "FinancialAdjustment on an accepted, not-yet-closed handover" do
    it "is reflected immediately in the sender's period contribution, leaving the original amount untouched" do
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

      expect(original_amount.reload.collected_amount).to eq(370)
    end

    it "propagates into the receiver's own period as the adjusted (not original) incoming amount" do
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

      # Hossam's one period: 470 (close) - 470 (adjusted incoming, not the original 370) = 0.
      expect(cash_amount(row_for(summarize(dr), a)).collected_amount).to eq(470)
      expect(cash_amount(row_for(summarize(dr), hossam)).collected_amount).to eq(0)
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
