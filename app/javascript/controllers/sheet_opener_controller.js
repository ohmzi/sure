import { Controller } from "@hotwired/stimulus";

// Opens a DS::Dialog sheet rendered inline in the page, by id: the sheet's own
// DS--dialog controller answers the `sheet:open` event.
export default class extends Controller {
  static values = { sheet: String };

  open() {
    document
      .getElementById(this.sheetValue)
      ?.dispatchEvent(new CustomEvent("sheet:open"));
  }
}
