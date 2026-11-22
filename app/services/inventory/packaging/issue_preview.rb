module Inventory
  module Packaging
    # What posting a stock issue would do to the warehouse's sealed packages,
    # read-only, from today's stock (Decision 6: shown before posting; posting
    # re-plans under the lock and is authoritative). { item id => Session::Preview }
    # for lines of packaged products only; empty when none.
    module IssuePreview
      module_function

      def call(issue)
        items = issue.items.reject(&:marked_for_destruction?).select(&:product)
        return {} if items.empty? || issue.warehouse_id.nil?

        session = Session.new(business: issue.business, product_ids: items.map(&:product_id), warehouse_ids: [ issue.warehouse_id ])
        items.each_with_object({}) do |item, previews|
          next unless session.packaged?(item.product_id)

          previews[item.id] = session.preview(product: item.product, warehouse_id: issue.warehouse_id) do |plan|
            item.package_line? ? plan.take_packages(item.packaging_level.position, item.entered_quantity) : plan.take_base(item.quantity)
          end
        end
      end

      # [[kind, package_unit, delta], …] for Format.steps.
      def step_data(preview, structure)
        preview.steps.map { |step| [ step.kind, structure.at(step.position).package_unit, step.delta ] }
      end
    end
  end
end
