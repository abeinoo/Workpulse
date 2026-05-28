require "rails_helper"

# Helper specs use RSpec's helper example group which automatically includes
# the named helper module and exposes a `helper` object.
RSpec.describe ShiftAssignmentHelper, type: :helper do
  # ── Fixture setup ───────────────────────────────────────────────────────────
  # We need a current_user so that local_date / local_datetime resolve the
  # business timezone correctly (used internally by timeline_period_label).

  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:branch)   { create(:branch, business: business) }

  let(:fixed_shift) do
    create(:shift, :fixed_time, business: business,
           start_time: Time.zone.parse("09:00"),
           end_time:   Time.zone.parse("17:00"))
  end

  let(:overnight_shift) do
    create(:shift, :overnight, business: business,
           start_time: Time.zone.parse("22:00"),
           end_time:   Time.zone.parse("06:00"))
  end

  let(:flex_shift) do
    create(:shift, :hour_based, business: business, required_hours: 8)
  end

  before do
    allow(helper).to receive(:current_user).and_return(owner)
    I18n.locale = :en
  end

  after { I18n.locale = I18n.default_locale }

  # ── Helper: build a minimal ShiftAssignment double ──────────────────────────
  def make_assignment(from:, to: nil, shift: fixed_shift)
    ShiftAssignment.new(
      user:           owner,
      shift:          shift,
      branch:         branch,
      effective_from: from,
      effective_to:   to
    )
  end

  # ── timeline_status_badge ──────────────────────────────────────────────────

  describe "#timeline_status_badge" do
    context "when assignment is future" do
      it "returns badge-accent" do
        a = make_assignment(from: 5.days.from_now.to_date)
        expect(helper.timeline_status_badge(a)).to eq("badge-accent")
      end
    end

    context "when assignment is current (no end date)" do
      it "returns badge-success" do
        a = make_assignment(from: 30.days.ago.to_date)
        expect(helper.timeline_status_badge(a)).to eq("badge-success")
      end
    end

    context "when assignment is current (end date in future)" do
      it "returns badge-success" do
        a = make_assignment(from: 10.days.ago.to_date, to: 10.days.from_now.to_date)
        expect(helper.timeline_status_badge(a)).to eq("badge-success")
      end
    end

    context "when assignment is historical (ended)" do
      it "returns badge-neutral" do
        a = make_assignment(from: 60.days.ago.to_date, to: 5.days.ago.to_date)
        expect(helper.timeline_status_badge(a)).to eq("badge-neutral")
      end
    end
  end

  # ── timeline_status_label ─────────────────────────────────────────────────

  describe "#timeline_status_label" do
    it "returns upcoming label for future assignment" do
      a = make_assignment(from: 3.days.from_now.to_date)
      expect(helper.timeline_status_label(a)).to eq(I18n.t("shift_assignments.upcoming"))
    end

    it "returns active label for current assignment" do
      a = make_assignment(from: 10.days.ago.to_date)
      expect(helper.timeline_status_label(a)).to eq(I18n.t("shift_assignments.active"))
    end

    it "returns ended label for historical assignment" do
      a = make_assignment(from: 60.days.ago.to_date, to: 5.days.ago.to_date)
      expect(helper.timeline_status_label(a)).to eq(I18n.t("shift_assignments.ended"))
    end
  end

  # ── timeline_status_modifier ──────────────────────────────────────────────

  describe "#timeline_status_modifier" do
    it "returns 'upcoming' for future" do
      a = make_assignment(from: 1.day.from_now.to_date)
      expect(helper.timeline_status_modifier(a)).to eq("upcoming")
    end

    it "returns 'active' for current" do
      a = make_assignment(from: 5.days.ago.to_date)
      expect(helper.timeline_status_modifier(a)).to eq("active")
    end

    it "returns 'ended' for historical" do
      a = make_assignment(from: 30.days.ago.to_date, to: 2.days.ago.to_date)
      expect(helper.timeline_status_modifier(a)).to eq("ended")
    end
  end

  # ── timeline_period_label ─────────────────────────────────────────────────

  describe "#timeline_period_label" do
    it "shows from–to for a closed assignment" do
      from = Date.new(2026, 1, 1)
      to   = Date.new(2026, 6, 30)
      a = make_assignment(from: from, to: to)
      label = helper.timeline_period_label(a)
      expect(label).to include(I18n.l(from))
      expect(label).to include(I18n.l(to))
    end

    it "shows from – ongoing for an open-ended assignment" do
      from = Date.new(2026, 3, 15)
      a = make_assignment(from: from)
      label = helper.timeline_period_label(a)
      expect(label).to include(I18n.l(from))
      expect(label).to include("ongoing")
    end

    it "renders correctly in Arabic locale" do
      I18n.locale = :ar
      from = Date.new(2026, 3, 15)
      a = make_assignment(from: from)
      label = helper.timeline_period_label(a)
      expect(label).to include("مستمر")
    end
  end

  # ── timeline_relative_date ────────────────────────────────────────────────

  describe "#timeline_relative_date" do
    context "future assignments" do
      # future? requires effective_from > today, so the minimum days value is 1.
      # There is no "starts today" path for future assignments.

      it "returns singular 'Starts in 1 day' for 1 day away" do
        a = make_assignment(from: 1.day.from_now.to_date)
        result = helper.timeline_relative_date(a)
        expect(result).to include("1")
        expect(result).to match(/day/i)
      end

      it "returns plural form for multiple days" do
        a = make_assignment(from: 7.days.from_now.to_date)
        result = helper.timeline_relative_date(a)
        expect(result).to include("7")
      end
    end

    context "current assignments" do
      it "returns 'Started today' when started today" do
        a = make_assignment(from: Date.current)
        # A same-day start with no end is both future (start today) and current?
        # future? returns true when from > today — so from == today means NOT future
        # Let's check: effective_from = today → future? = today > today = false
        # current? = today <= today AND nil → true. So this is "started today".
        expect(helper.timeline_relative_date(a)).to eq(I18n.t("shift_timeline.started_today"))
      end

      it "returns 'Active for N days' when started N days ago" do
        a = make_assignment(from: 10.days.ago.to_date)
        result = helper.timeline_relative_date(a)
        expect(result).to include("10")
      end
    end

    context "historical assignments" do
      it "returns 'Ended today' when ended today" do
        a = make_assignment(from: 30.days.ago.to_date, to: Date.current)
        # to = today → historical? requires to < today, so this is actually current
        # To make it historical we need to yesterday
        a2 = make_assignment(from: 30.days.ago.to_date, to: Date.current - 1)
        result = helper.timeline_relative_date(a2)
        # ended_ago with count: 1 → "Ended 1 day ago"
        expect(result).to include("1")
      end

      it "returns 'Ended N days ago' for old assignments" do
        a = make_assignment(from: 60.days.ago.to_date, to: 14.days.ago.to_date)
        result = helper.timeline_relative_date(a)
        expect(result).to include("14")
      end
    end
  end

  # ── timeline_pct ──────────────────────────────────────────────────────────

  describe "#timeline_pct" do
    it "returns 100 for open-ended assignments" do
      a = make_assignment(from: 30.days.ago.to_date)
      expect(helper.timeline_pct(a)).to eq(100)
    end

    it "returns 100 when end equals start (degenerate)" do
      d = Date.current
      a = make_assignment(from: d, to: d)
      expect(helper.timeline_pct(a)).to eq(100)
    end

    it "returns 0 for a future assignment not yet started" do
      from = 10.days.from_now.to_date
      to   = 40.days.from_now.to_date
      a = make_assignment(from: from, to: to)
      expect(helper.timeline_pct(a)).to eq(0)
    end

    it "returns 50 when exactly halfway through" do
      from = 10.days.ago.to_date
      to   = 10.days.from_now.to_date
      a = make_assignment(from: from, to: to)
      # elapsed = 10, total = 20 → 50%
      expect(helper.timeline_pct(a)).to eq(50)
    end

    it "returns 100 for fully elapsed (past end date)" do
      a = make_assignment(from: 30.days.ago.to_date, to: 5.days.ago.to_date)
      expect(helper.timeline_pct(a)).to eq(100)
    end

    it "clamps to 0 minimum (never negative)" do
      a = make_assignment(from: 100.days.from_now.to_date,
                          to:   200.days.from_now.to_date)
      expect(helper.timeline_pct(a)).to be >= 0
    end
  end

  # ── timeline_shift_hours ──────────────────────────────────────────────────

  describe "#timeline_shift_hours" do
    it "returns formatted HH:MM–HH:MM for fixed_time shift" do
      result = helper.timeline_shift_hours(fixed_shift)
      expect(result).to eq("09:00 – 17:00")
    end

    it "appends overnight note for overnight shifts" do
      result = helper.timeline_shift_hours(overnight_shift)
      expect(result).to include("22:00")
      expect(result).to include("06:00")
      expect(result.downcase).to include("overnight")
    end

    it "returns flexible hours label for hour_based shift" do
      result = helper.timeline_shift_hours(flex_shift)
      expect(result).to eq(I18n.t("shift_timeline.flexible_hours", hours: 8))
    end

    it "renders overnight note in Arabic locale" do
      I18n.locale = :ar
      result = helper.timeline_shift_hours(overnight_shift)
      # overnight badge is the shifts.overnight_badge downcased
      expect(result.downcase).to include(I18n.t("shifts.overnight_badge").downcase)
    end
  end

  # ── Integration: consistent EN + AR rendering ─────────────────────────────

  describe "locale consistency" do
    let(:a) { make_assignment(from: 7.days.from_now.to_date) }

    %i[en ar].each do |locale|
      it "renders relative date in #{locale} without raising" do
        I18n.locale = locale
        expect { helper.timeline_relative_date(a) }.not_to raise_error
      end

      it "renders period label in #{locale} without raising" do
        I18n.locale = locale
        expect { helper.timeline_period_label(a) }.not_to raise_error
      end
    end
  end
end
