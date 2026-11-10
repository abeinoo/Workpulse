module Finance
  # The one remainder-on-last-row split: every part but the last is rounded to
  # 2 dp (BigDecimal#round — half away from zero) and the last part takes the
  # exact residual, so the parts always sum to `total`. Parts keep the caller's
  # order; the block gives the unrounded share of part `i` and is never called
  # for the last part. No validation: zero, negative and non-100 inputs are
  # split as given, and the caller decides what the parts mean.
  #
  #   Finance::MoneySplitter.split(100, 3) { BigDecimal(100) / 3 } # => [33.33, 33.33, 33.34]
  #
  # Used by AllocationCalculator (percentages and amounts) and
  # PayrollInsuranceExpense (percentages from exact branch amounts).
  module MoneySplitter
    module_function

    def split(total, count)
      running = BigDecimal(0)
      Array.new(count) do |i|
        next total - running if i == count - 1

        part = yield(i).round(2)
        running += part
        part
      end
    end
  end
end
