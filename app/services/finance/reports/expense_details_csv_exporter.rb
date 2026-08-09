require "csv"

module Finance
  module Reports
    # Renders a Finance::Reports::ExpenseDetails::Result to CSV. Unlike
    # Finance::Reports::CsvExporter (strictly flat Table rows), this walks the
    # section → group → row hierarchy and emits one line per leaf detail row,
    # plus a subtotal row per group and a grand-total row per section — so the
    # export matches the full visible hierarchy, not just totals. Row shape
    # differs per section (employee columns vs expense columns vs inventory
    # columns), so the CSV uses one fixed, denormalized column superset and
    # leaves irrelevant columns blank per row.
    class ExpenseDetailsCsvExporter
      BOM = "﻿".freeze

      COLUMNS = %i[section branch label category reference date base_salary overtime bonus
                   deduction net quantity unit_cost amount].freeze

      def initialize(result)
        @result = result
      end

      def to_csv
        BOM + CSV.generate do |csv|
          csv << COLUMNS.map { |c| I18n.t("finance.reports.expense_details.csv.#{c}", default: c.to_s.humanize) }
          @result.sections.each { |section| write_section(csv, section) }
        end
      end

      private

      def write_section(csv, section)
        section.groups.each { |group| write_group(csv, section, group) }
        csv << row(section: section.title, label: I18n.t("finance.reports.total"), amount: section.total)
      end

      def write_group(csv, section, group)
        group.rows.each { |detail| csv << detail_row(section, group, detail) }
        csv << row(section: section.title, branch: group.label, label: I18n.t("finance.reports.total"), amount: group.subtotal)
      end

      def detail_row(section, group, detail)
        case section.key
        when :payroll
          row(section: section.title, branch: group.label, label: detail[:employee_name],
              base_salary: detail[:base_salary], overtime: detail[:total_overtime], bonus: detail[:total_bonuses],
              deduction: detail[:total_deductions], net: detail[:net_salary], amount: detail[:gross])
        when :laundry
          row(section: section.title, branch: group.label, label: detail[:towel_type],
              date: detail[:received_at], quantity: detail[:confirmed_quantity], unit_cost: detail[:rate],
              amount: detail[:line_total])
        when :inventory
          row(section: section.title, branch: group.label, label: detail[:product]&.name, category: detail[:category],
              quantity: detail[:quantity], unit_cost: detail[:unit_cost], amount: detail[:total])
        when :branch_expenses, :shared_expenses, :other
          row(section: section.title, branch: group.label, label: detail[:category], category: detail[:type],
              reference: detail[:reference], date: detail[:date], amount: detail[:amount])
        else
          row(section: section.title, branch: group.label, amount: detail[:amount])
        end
      end

      def row(section: nil, branch: nil, label: nil, category: nil, reference: nil, date: nil,
               base_salary: nil, overtime: nil, bonus: nil, deduction: nil, net: nil,
               quantity: nil, unit_cost: nil, amount: nil)
        values = {
          section: section, branch: branch, label: label, category: category, reference: reference,
          date: date, base_salary: base_salary, overtime: overtime, bonus: bonus, deduction: deduction,
          net: net, quantity: quantity, unit_cost: unit_cost, amount: amount
        }
        COLUMNS.map { |key| values[key] }
      end
    end
  end
end
