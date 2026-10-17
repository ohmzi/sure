import { Controller } from "@hotwired/stimulus";

// Lights a tapped navigation entry up the moment it is pressed. The entry's
// active look is keyed on aria-current (layouts/shared/_nav_item), so moving
// that attribute is the whole job; the page that arrives renders the same
// state, so nothing has to be undone.
export default class extends Controller {
  press(event) {
    if (event.defaultPrevented || event.button > 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
      return;
    const link = event.target.closest("a[href]");
    if (!link || !this.element.contains(link)) return;

    for (const current of this.element.querySelectorAll("a[aria-current]")) {
      current.removeAttribute("aria-current");
    }
    link.setAttribute("aria-current", "page");
  }
}
