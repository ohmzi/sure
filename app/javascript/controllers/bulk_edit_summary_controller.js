import { Controller } from "@hotwired/stimulus";

// The bulk edit sheet (the owner's design, 2026-10-19): marks each row whose
// field has been filled in as one that will change, counts them in the
// footer, and leaves the transactions' tags alone unless some were picked.
// Only fields named `bulk_update[...]` count, so a picker's search box does
// not.
export default class extends Controller {
  static targets = ["row", "summary"];
  static values = { none: String, one: String, other: String };

  connect() {
    this.refresh();
  }

  refresh() {
    let count = 0;
    for (const row of this.rowTargets) {
      const changed = this.#filled(row);
      row.toggleAttribute("data-changed", changed);
      if (changed) count++;
    }
    if (this.hasSummaryTarget) {
      this.summaryTarget.textContent =
        count === 0
          ? this.noneValue
          : count === 1
            ? this.oneValue
            : this.otherValue.replace("%{count}", count);
    }
  }

  // Pickers set their hidden inputs from click handlers without an input
  // event, so a click looks again once they have.
  refreshSoon() {
    requestAnimationFrame(() => this.refresh());
  }

  // The tag picker always carries a blank tag field, and any `tag_ids` tells
  // the server to replace the tags: with none picked, send none.
  keepTagsUnlessPicked() {
    const tags = Array.from(
      this.element.querySelectorAll('input[name="bulk_update[tag_ids][]"]'),
    );
    if (tags.every((input) => input.value === "")) {
      for (const input of tags) input.remove();
    }
  }

  #filled(row) {
    return Array.from(
      row.querySelectorAll(
        'input[name^="bulk_update["], select[name^="bulk_update["], textarea[name^="bulk_update["]',
      ),
    ).some((field) => {
      if (field.disabled) return false;
      if (field.tagName === "SELECT") {
        return Array.from(field.selectedOptions).some(
          (option) => option.value !== "",
        );
      }
      return field.value.trim() !== "";
    });
  }
}
