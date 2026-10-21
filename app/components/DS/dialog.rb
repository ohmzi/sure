class DS::Dialog < DesignSystemComponent
  renders_one :header, ->(title: nil, subtitle: nil, custom_header: false, **opts, &block) do
    # On a phone the title row drags the sheet down as the grabber does.
    header_data = { action: "pointerdown->DS--dialog#dragStart" }.merge(opts[:data] || {})
    content_tag(:header, class: "px-4 flex flex-col gap-2", **opts, data: header_data) do
      title_div = content_tag(:div, class: "flex items-center justify-between gap-2") do
        # `id: title_id` lets the host `<dialog>` reference the title via
        # `aria-labelledby` so AT users hear the title when focus lands
        # in the dialog. `content_tag("h#{heading_level}", ...)` builds an
        # h2/h3/etc based on the caller's `heading_level:`.
        title = content_tag("h#{heading_level}", title, id: title_id, class: class_names("text-2xl leading-8 font-extrabold tracking-tight text-primary")) if title
        close_icon = close_button unless custom_header
        safe_join([ title, close_icon ].compact)
      end

      subtitle = content_tag(:p, subtitle, class: "text-sm text-secondary") if subtitle

      block_content = capture(&block) if block

      safe_join([ title_div, subtitle, block_content ].compact)
    end
  end

  renders_one :body

  # The iOS sheet header (variant "sheet"): a leading action (Cancel, Reset), the
  # centred title the dialog is labelled by, and a trailing action (Done). It
  # sits above the scrolling body, so it stays put while the sheet scrolls.
  renders_one :sheet_header, ->(title:, leading: nil, trailing: nil) do
    content_tag(:header, class: "grid grid-cols-3 items-center gap-2 px-4 pb-2 lg:pt-4 shrink-0") do
      safe_join([
        content_tag(:div, leading, class: "justify-self-start"),
        content_tag("h#{heading_level}", title, id: title_id, class: "justify-self-center whitespace-nowrap text-base font-semibold text-primary"),
        content_tag(:div, trailing, class: "justify-self-end")
      ])
    end
  end

  renders_many :actions, ->(cancel_action: false, **button_opts) do
    merged_opts = if cancel_action
      button_opts.merge(type: "button", data: { action: "DS--dialog#close" })
    else
      button_opts
    end

    render DS::Button.new(**merged_opts)
  end

  renders_many :sections, ->(title:, **disclosure_opts, &block) do
    render DS::Disclosure.new(title: title, align: :right, **disclosure_opts) do
      block.call
    end
  end

  attr_reader :variant, :auto_open, :reload_on_close, :width, :disable_frame, :content_class, :disable_click_outside, :opts, :responsive, :scrollable, :heading_level, :title_id

  # `sheet` (Documents redesign, 2026-10-16) is the iOS bottom sheet: below lg
  # it rises from the bottom edge with a grabber to drag it down by; from lg up
  # it is a centered panel. It never opens on render (pass `auto_open: false`):
  # a page renders it inline and opens it with a `sheet:open` event.
  VARIANTS = %w[modal drawer sheet].freeze
  # `expanded` is the "give this cramped thing the whole screen" shape used by
  # expand-on-hover affordances (the dashboard cashflow chart, the debug log
  # table). It keeps a sliver of viewport margin — unlike `full` — and caps out
  # so wide tables and charts don't stretch unreadably on ultrawide displays.
  #
  # The 96vw only applies from `lg`, where `dialog_inner_classes` drops the
  # `mx-3` gutter. Below that, a viewport-relative width is the wrong tool:
  # `vw` counts the scrollbar but the dialog's own box does not, so 96vw + the
  # 24px gutter overflows a phone by ~11px per side (measured 320–390px), and
  # flex-shrink cannot absorb it once nowrap content raises the panel's
  # min-content width. Below `lg` the base `w-full` + `mx-3` already fits.
  WIDTHS = {
    sm: "lg:max-w-[300px]",
    md: "lg:max-w-[550px]",
    lg: "lg:max-w-[700px]",
    full: "lg:max-w-full",
    expanded: "lg:!w-[96vw] max-w-[1650px]"
  }.freeze
  VALID_HEADING_LEVELS = (1..6).freeze

  class_attribute :defaults_provider, default: nil

  def initialize(variant: "modal", auto_open: true, reload_on_close: false, width: "md", frame: nil, disable_frame: false, content_class: nil, disable_click_outside: nil, responsive: false, scrollable: true, heading_level: 2, **opts)
    unless heading_level.is_a?(Integer) && VALID_HEADING_LEVELS.cover?(heading_level)
      raise ArgumentError, "heading_level must be an Integer between 1 and 6, got: #{heading_level.inspect}"
    end

    defaults = self.class.defaults_provider&.call || {}

    @variant = variant.to_sym
    @auto_open = auto_open
    @reload_on_close = reload_on_close
    @width = width.to_sym
    @frame = frame
    @disable_frame = disable_frame
    @content_class = content_class
    @disable_click_outside = disable_click_outside.nil? ? defaults.fetch(:disable_click_outside, false) : disable_click_outside
    @responsive = responsive
    @scrollable = scrollable
    @heading_level = heading_level
    @title_id = "dialog-title-#{SecureRandom.hex(4)}"
    @opts = opts
  end

  def frame
    @frame || variant
  end

  # Caller must "opt-out" of using the default turbo-frame based on the variant
  def wrapper_element(&block)
    if disable_frame
      content_tag(:div, &block)
    else
      content_tag("turbo-frame", id: frame, &block)
    end
  end

  # Every dialog is the same bottom sheet on a phone (the owner's rule,
  # 2026-10-17): below lg it rises from the bottom edge, full width, with the
  # grabber, its own safe-area padding and the blurred backdrop. From lg up
  # each variant keeps its shape — a centred modal, a drawer on the right, the
  # sheet's centred panel.
  def dialog_classes
    class_names(
      "w-full h-full bg-transparent text-primary backdrop:bg-overlay backdrop:backdrop-blur-sm pt-[env(safe-area-inset-top)]",
      # The backdrop fades in with the sheet, lightens as it is dragged down
      # and fades out as it leaves (--sheet-backdrop, set by the controller;
      # the owner, 2026-10-19).
      "backdrop:opacity-(--sheet-backdrop,1) backdrop:transition-opacity backdrop:duration-300 backdrop:starting:opacity-0 motion-reduce:backdrop:transition-none",
      (drawer? || responsive? || sheet?) ? "lg:p-3" : "lg:p-1"
    )
  end

  def dialog_outer_classes
    variant_classes = if sheet?
      "items-end justify-center lg:items-center"
    elsif responsive? || drawer?
      "items-end justify-center lg:justify-end"
    else
      "items-end justify-center lg:items-center"
    end

    class_names(
      "flex h-full w-full",
      variant_classes
    )
  end

  def dialog_inner_classes
    variant_classes = if sheet?
      class_names(WIDTHS[width], "lg:starting:translate-y-0 lg:starting:scale-95 lg:starting:opacity-0")
    elsif responsive?
      "lg:max-h-full lg:h-full lg:w-[550px]"
    elsif drawer?
      "lg:max-h-full lg:h-full lg:w-[550px]"
    else
      class_names("lg:max-h-full", WIDTHS[width])
    end

    class_names(
      "flex flex-col w-full max-h-[92dvh] bg-surface shadow-border-xl",
      "rounded-t-[2rem] lg:rounded-[1.75rem] pb-[env(safe-area-inset-bottom)] lg:pb-0",
      # Below lg it rises on open (`starting:`) on the curve iOS sheets use,
      # settling rather than stopping; a sheet also fades up as a panel from lg.
      "transition-[transform,opacity] duration-300 ease-out max-lg:duration-[420ms] max-lg:ease-[cubic-bezier(0.32,0.72,0,1)] motion-reduce:transition-none",
      "max-lg:starting:translate-y-full",
      variant_classes,
      content_class
    )
  end

  def merged_opts
    merged_opts = opts.dup
    data = merged_opts.delete(:data) || {}

    data[:controller] = [ "DS--dialog", "hotkey", data[:controller] ].compact.join(" ")
    data[:DS__dialog_auto_open_value] = auto_open
    data[:DS__dialog_reload_on_close_value] = reload_on_close
    data[:DS__dialog_disable_click_outside_value] = disable_click_outside
    data[:DS__dialog_sheet_value] = sheet?
    data[:action] = [
      "click->DS--dialog#clickOutside",
      ("sheet:open->DS--dialog#open sheet:close->DS--dialog#close" if sheet?),
      data[:action]
    ].compact.join(" ")
    data[:hotkey] = "esc:DS--dialog#close"
    # Fetched into a frame over the page, the dialog is left out of Turbo's
    # cached copy of that page, or Back brings it back: stray if it was still
    # open, opened again if it was closed. Visited directly, it is the page and
    # stays. Turbo also caches the live page right after any frame visit with
    # data-turbo-action renders, and that removes these dialogs, so don't open
    # one that way or make such a visit while one is open.
    data[:turbo_temporary] = true if helpers.turbo_frame_request_id == frame.to_s
    merged_opts[:data] = data

    merged_opts
  end

  def drawer?
    variant == :drawer
  end

  def sheet?
    variant == :sheet
  end

  def responsive?
    @responsive
  end

  # Shown at every width: responsive dialogs use it as their only close
  # control on phones too. shrink-0 keeps its square beside a long title in a
  # custom header. A round, filled button, easy to find and to hit
  # (2026-10-19).
  def close_button
    classes = class_names("rounded-full bg-container-inset hover:bg-container-inset-hover", "ml-auto shrink-0")
    render DS::Button.new(
      variant: "icon",
      size: :sm,
      class: classes,
      icon: "x",
      title: I18n.t("ds.dialog.close"),
      aria_label: I18n.t("ds.dialog.close"),
      data: { action: "DS--dialog#close" }
    )
  end
end
