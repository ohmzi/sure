class DS::Section < DesignSystemComponent
  # A titled list: a heading row (the title, "· N" and an optional aside on
  # the right) over a card that holds the rows. Extracted from the Bills
  # overview, whose notices, review queues and bill sections each built it by
  # hand (#3957).
  #
  #   <%= render DS::Section.new(title: t(".needs_review"), count: rows.size) do |section| %>
  #     <% section.with_aside { tag.p(total, class: "text-xs text-secondary") } %>
  #     <% rows.each do |row| %>...<% end %>
  #   <% end %>
  #
  # The card is the rows' query container. With both sidebars open a list is
  # phone-width at a desktop viewport, so rows size themselves against the
  # card, not the screen.
  renders_one :aside

  attr_reader :title, :count, :collapsible, :persist_key, :inset

  # @param title [String] an h2, so the sections join the page's outline
  # @param count [Integer] the "· N" after the title
  # @param collapsible [Boolean] make the heading row a summary with a chevron,
  #   for a list that can run long. It starts open.
  # @param persist_key [String, nil] remember a collapsed section on this device
  #   (persisted-disclosure); only for a collapsible section
  # @param inset [Boolean] kept for callers; it no longer draws anything. The
  #   section used to sit in a surface-inset shell with its card 4px inside
  #   it, which read as a card in a card (the owner, 2026-10-18). Now the
  #   heading sits on the page above one card, like an iOS grouped list.
  def initialize(title:, count:, collapsible: false, persist_key: nil, inset: true)
    @title = title
    @count = count
    @collapsible = collapsible
    @persist_key = persist_key
    @inset = inset

    raise ArgumentError, "persist_key: needs collapsible: true" if persist_key && !collapsible
  end

  def container_classes
    "space-y-1"
  end

  def persist_data
    { controller: "persisted-disclosure", persisted_disclosure_key_value: persist_key } if persist_key
  end
end
