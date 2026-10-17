import { Controller } from "@hotwired/stimulus";

// The Filters sheet applies only on Show results or Done (a submit, which
// replaces the page). Closed any other way — Cancel by drag, the backdrop,
// Escape — its fields go back to what the page was rendered with, as an iOS
// sheet discards unsaved changes.
export default class extends Controller {
  discard() {
    for (const field of this.element.querySelectorAll("input, select")) {
      if (field.type === "checkbox" || field.type === "radio") {
        field.checked = field.defaultChecked;
      } else if (field.tagName === "SELECT") {
        for (const option of field.options)
          option.selected = option.defaultSelected;
      } else {
        field.value = field.defaultValue;
      }
    }
  }
}
