import { Controller } from "@hotwired/stimulus";
import { revealOnView } from "utils/reveal_on_view";

// For a chart drawn on the server (an SVG ring, CSS bars): it shimmers until
// it scrolls into view, then plays its entrance (utils/reveal_on_view).
export default class extends Controller {
  connect() {
    this.stop = revealOnView(this.element);
  }

  disconnect() {
    this.stop?.();
  }
}
