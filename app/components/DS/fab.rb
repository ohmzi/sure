# frozen_string_literal: true

# The floating action button (the Quicken Simplifi design language,
# 2026-10-17): one round, brand-coloured button pinned over the main content's
# bottom-right corner — above the phone's bottom bar and clear of the desktop
# assistant sidebar (floating_action_controller.js). A button by default (pass
# `data:` to wire it), a link with `href:` (and `frame:` to open it in one).
class DS::Fab < DesignSystemComponent
  CLASSES = "fixed z-20 right-4 bottom-[calc(5.75rem+env(safe-area-inset-bottom))] lg:bottom-8 " \
            "inline-flex items-center justify-center size-14 rounded-full bg-inverse hover:bg-inverse-hover " \
            "text-inverse shadow-lg active:scale-95 transition focus-ring"

  def initialize(icon:, label:, href: nil, frame: nil, **opts)
    @icon = icon
    @label = label
    @href = href
    @frame = frame
    @opts = opts
  end

  def call
    extra_class = @opts.delete(:class)
    data = (@opts.delete(:data) || {}).dup
    data[:controller] = [ "floating-action", data[:controller] ].compact.join(" ")
    data[:turbo_frame] = @frame if @frame
    attributes = @opts.merge(class: class_names(CLASSES, extra_class), title: @label, aria: { label: @label }.merge(@opts[:aria] || {}), data: data)
    glyph = helpers.icon(@icon, size: "xl", color: "current")

    if @href
      link_to(glyph, @href, **attributes)
    else
      content_tag(:button, glyph, type: "button", **attributes)
    end
  end
end
