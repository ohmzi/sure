import { Controller } from "@hotwired/stimulus";

// Drives the inline assignment field on each envelope row. The row's form
// carries the target id; this controller only forwards submit-on-Enter and
// keeps focus.
export default class extends Controller {
  static targets = ["amount"];

  submit(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      event.target.closest("form").requestSubmit();
    }
  }
}
