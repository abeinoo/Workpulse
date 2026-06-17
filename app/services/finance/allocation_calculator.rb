module Finance
  # Computes per-branch allocated_amount for a shared expense from its allocation
  # percentages, so the amounts always sum back to the expense total to the cent.
  #
  # Three modes (the controller picks one from the form):
  #   :equal      → split evenly across the chosen branches (percentages set too)
  #   :percentage → percentages are given; amounts derived from them
  #   :manual     → amounts are given directly; percentages derived from them
  #
  # Rounding: amounts are rounded to 2 dp and the final allocation absorbs any
  # residual so Σ allocated_amount == expense.amount exactly.
  class AllocationCalculator
    def initialize(expense, mode: :percentage)
      @expense = expense
      @mode    = mode.to_sym
    end

    # Mutates the in-memory allocation rows; the caller saves the expense.
    def call
      allocations = @expense.expense_allocations.reject(&:marked_for_destruction?)
      return @expense if allocations.empty?

      case @mode
      when :equal      then apply_equal(allocations)
      when :manual     then apply_manual(allocations)
      else                  apply_percentage(allocations)
      end
      @expense
    end

    private

    def total
      @total ||= @expense.amount.to_d
    end

    def apply_equal(allocations)
      n   = allocations.size
      pct = (BigDecimal(100) / n).round(2)
      allocations.each { |a| a.allocation_percentage = pct }
      distribute_amounts(allocations)
    end

    def apply_percentage(allocations)
      distribute_amounts(allocations)
    end

    # Amounts are authoritative; derive each percentage from the entered amount.
    def apply_manual(allocations)
      allocations.each do |a|
        amt = a.allocated_amount.to_d
        a.allocation_percentage = total.zero? ? 0 : (amt / total * 100).round(2)
      end
    end

    # Set allocated_amount from each percentage, then push the rounding residual
    # onto the last row so the parts sum exactly to the total.
    def distribute_amounts(allocations)
      running = BigDecimal(0)
      allocations.each_with_index do |a, i|
        if i == allocations.size - 1
          a.allocated_amount = (total - running)
        else
          amt = (total * a.allocation_percentage.to_d / 100).round(2)
          a.allocated_amount = amt
          running += amt
        end
      end
    end
  end
end
