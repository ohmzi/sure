module EntriesHelper
  SplitGroup = Data.define(:parent, :children)

  def group_split_entries(entries, split_parents)
    return entries if split_parents.blank?

    result = []
    seen_parent_ids = Set.new

    entries.each do |entry|
      if entry.split_child? && split_parents[entry.parent_entry_id]
        parent_id = entry.parent_entry_id
        next if seen_parent_ids.include?(parent_id)

        seen_parent_ids.add(parent_id)
        children = entries.select { |e| e.parent_entry_id == parent_id }
        result << SplitGroup.new(parent: split_parents[parent_id], children: children)
      else
        result << entry
      end
    end

    result
  end

  # Days run newest first unless `order` says otherwise: :asc for oldest
  # first, or :sequence to keep the entries' own order (a list sorted by
  # amount), where each run of one day gets its own header (the owner,
  # 2026-10-18).
  #
  # With `months: true` (Activity, the owner, 2026-10-19) the days of a month
  # sit together in one card under the month's name, each opened by a slim
  # line naming the day, instead of a card per day — most days hold one
  # transaction, and a header and a card each read as clutter. A list sorted
  # by amount sits in a single card.
  def entries_by_date(entries, totals: false, order: :desc, months: false)
    transfer_groups = entries.group_by do |entry|
      # Only check for transfer if it's a transaction
      next nil unless entry.entryable_type == "Transaction"
      entry.entryable.transfer&.id
    end

    # For a more intuitive UX, we do not want to show the same transfer twice in the list
    deduped_entries = transfer_groups.flat_map do |transfer_id, grouped_entries|
      if transfer_id.nil? || grouped_entries.size == 1
        grouped_entries
      else
        grouped_entries.reject do |e|
          e.entryable_type == "Transaction" &&
          e.entryable.transfer_as_inflow.present?
        end
      end
    end

    groups = case order
    when :sequence
      deduped_entries.chunk_while { |a, b| a.date == b.date }.each_with_index.map { |run, i| [ run.first.date, run, "#{run.first.date}-#{i}" ] }
    when :asc
      deduped_entries.group_by(&:date).sort.map { |date, run| [ date, run, date ] }
    else
      deduped_entries.group_by(&:date).sort.reverse_each.map { |date, run| [ date, run, date ] }
    end

    rendered = groups.filter_map do |date, grouped_entries, key|
      content = capture do
        yield grouped_entries
      end

      next if content.blank?

      [ date, grouped_entries, render(partial: "entries/entry_group", locals: { date:, entries: grouped_entries, content:, totals:, key:, nested: months }) ]
    end
    return rendered.map(&:last).join.html_safe unless months

    chunks = order == :sequence ? [ rendered ] : rendered.chunk_while { |a, b| a.first.beginning_of_month == b.first.beginning_of_month }
    chunks.reject(&:empty?).map do |chunk|
      render partial: "entries/month_group", locals: {
        month: (chunk.first.first.beginning_of_month unless order == :sequence),
        entries: chunk.flat_map(&:second),
        content: safe_join(chunk.map(&:last)),
        totals:
      }
    end.join.html_safe
  end

  # A day as its line in a month's card names it: "Today", "Yesterday", or
  # "Mon, Sep 21".
  def entry_day_label(date)
    return t("entries.day.today") if date == Date.current
    return t("entries.day.yesterday") if date == Date.current - 1.day

    "#{l(date, format: "%a")}, #{l(date, format: :short)}"
  end

  def entry_name_detailed(entry)
    [
      entry.date,
      format_money(entry.amount_money),
      entry.account.name,
      entry.name
    ].join(" • ")
  end
end
