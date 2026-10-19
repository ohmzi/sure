import { Controller } from "@hotwired/stimulus";

// The transactions Filters sheet counts what is checked across its panels
// (the owner, 2026-10-19): Apply reads "Apply (3)" once any box is on, and
// plain "Apply" when none is. Select all checks every account.
export default class extends Controller {
  static targets = ["submit", "accounts"];
  static values = { label: String, countLabel: String };

  connect() {
    this.update();
  }

  update() {
    const count = this.element.querySelectorAll(
      "input[type=checkbox]:checked",
    ).length;
    this.submitTarget.textContent =
      count > 0
        ? this.countLabelValue.replace("%{count}", count)
        : this.labelValue;
  }

  selectAll() {
    for (const box of this.accountsTarget.querySelectorAll(
      "input[type=checkbox]",
    )) {
      box.checked = true;
    }
    this.update();
  }
}
