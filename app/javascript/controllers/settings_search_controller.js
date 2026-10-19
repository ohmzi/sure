import { Controller } from "@hotwired/stimulus";

// Filters the Settings list as you type (the Settings audit, the owner,
// 2026-10-19): a row stays if its label or its group's name has every word
// typed, a group with no rows left hides, and an empty result says so.
export default class extends Controller {
  static targets = ["input", "row", "section", "empty"];

  filter() {
    const words = this.inputTarget.value
      .toLowerCase()
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    for (const row of this.rowTargets) {
      const text = row.dataset.searchText.toLowerCase();
      row.hidden = !words.every((word) => text.includes(word));
    }
    let any = false;
    for (const section of this.sectionTargets) {
      const visible =
        section.querySelectorAll(
          "[data-settings-search-target='row']:not([hidden])",
        ).length > 0;
      section.hidden = !visible;
      any ||= visible;
    }
    this.emptyTarget.classList.toggle("hidden", any);
  }

  clear() {
    this.inputTarget.value = "";
    this.filter();
  }
}
