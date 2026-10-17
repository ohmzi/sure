class DS::SegmentedControl < DesignSystemComponent
  # A single-select pill group — filters, mode switches, compact view toggles.
  # NOT the full ARIA tab/panel widget; use DS::Tabs for tabs-with-panels.
  #
  # Each segment is a link (pass `href:`) or a button (default — pass `data:`
  # for a Stimulus-driven control). Mark the current one with `active: true`.
  # The selected style lives in `.segmented-control__segment--active`, so a
  # controller can toggle selection by flipping that one class.
  #
  # `full_width: true` stretches segments to equal width (the "equal-footprint"
  # the #2137 audit asked for); default is content width.
  renders_many :segments, ->(label, active: false, href: nil, **opts) do
    # `focus-ring` is for link segments — button segments already get the
    # canonical outline from the base-layer button rule (it's an idempotent
    # duplicate there).
    classes = class_names(
      "segmented-control__segment focus-ring",
      ("flex-1" if full_width),
      ("segmented-control__segment--active" if active && !sliding),
      # Sliding: the one indicator is the pill, so a segment paints no
      # background of its own (not even on hover) and sits above it.
      ("relative z-10 hover:bg-transparent" if sliding),
      ("text-primary" if active && sliding),
      opts.delete(:class)
    )

    if sliding
      data = (opts.delete(:data) || {}).merge(segmented_slide_target: "segment", active: active.to_s)
      data[:action] = [ "click->segmented-slide#select", data[:action] ].compact.join(" ")
      opts[:data] = data
    end

    # Expose the selected state to assistive tech: link segments use
    # `aria-current`, button segments use `aria-pressed`. A Stimulus
    # controller that toggles `--active` should mirror these (see
    # budget_filter_controller#filterValueChanged).
    if href
      link_to(label, href, class: classes, "aria-current": (active ? "true" : nil), **opts)
    else
      content_tag(:button, label, type: "button", class: classes, "aria-pressed": active.to_s, **opts)
    end
  end

  attr_reader :full_width, :aria_label, :sliding

  # `sliding: true` (opt-in) is the iOS control: one pill that slides to the
  # chosen segment (segmented_slide_controller.js) instead of each segment
  # painting its own active background. The pill is the `tab-item-active`
  # token, the same colour the static active segment uses.
  def initialize(full_width: false, aria_label: nil, sliding: false, **opts)
    @full_width = full_width
    @aria_label = aria_label
    @sliding = sliding
    @opts = opts
  end

  def wrapper_attributes
    attributes = @opts.except(:class)
    return attributes unless sliding

    data = (attributes[:data] || {}).dup
    data[:controller] = [ "segmented-slide", data[:controller] ].compact.join(" ")
    attributes.merge(data: data)
  end

  erb_template <<~ERB
    <%= content_tag :div,
          class: class_names("segmented-control", ("w-full" if full_width), ("relative" if sliding), @opts[:class]),
          role: "group",
          "aria-label": aria_label,
          **wrapper_attributes do %>
      <% if sliding %>
        <span aria-hidden="true" data-segmented-slide-target="indicator"
              class="absolute top-1 bottom-1 left-0 rounded-full tab-item-active shadow-sm opacity-0 transition-[transform,width] duration-300 ease-out motion-reduce:transition-none"></span>
      <% end %>
      <% segments.each do |segment| %><%= segment %><% end %>
    <% end %>
  ERB
end
