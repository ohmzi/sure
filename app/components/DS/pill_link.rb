# A small, high-emphasis link shaped as a pill. The "needs you" strip repeats
# this action five times; it is a primitive so the shape (and its touch target)
# has one definition rather than five copies.
#
# It is a link, not a badge: use DS::Pill for status and category labels.
class DS::PillLink < DesignSystemComponent
  attr_reader :text, :href, :opts

  def initialize(text:, href:, **opts)
    @text = text
    @href = href
    @opts = opts
  end

  def container_classes
    class_names(
      # h-10 is the visual size; pointer-coarse grows the target to 44px
      # (WCAG 2.5.5 / the design system's touch target) on touch devices.
      "inline-flex items-center justify-center h-10 px-5 rounded-full",
      "bg-container text-link text-sm font-semibold",
      "hover:bg-container-hover active:scale-95 transition focus-ring",
      "pointer-coarse:h-11 pointer-coarse:px-6",
      opts[:class]
    )
  end

  erb_template <<~ERB
    <%= link_to text, href, **opts.merge(class: container_classes) %>
  ERB
end
