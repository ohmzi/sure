import { Controller } from "@hotwired/stimulus";

// The viewer modal (M8 locked decision 3): arrow keys click the rendered
// prev/next links (Turbo owns the frame swap), wheel/click zoom a lightbox
// image via a CSS transform. No dependencies.
export default class extends Controller {
  static targets = ["image"];
  static values = { zoomStep: { type: Number, default: 0.5 } };

  previous() {
    this.#navigate("previous");
  }

  next() {
    this.#navigate("next");
  }

  zoom(event) {
    if (!this.hasImageTarget) return;
    event.preventDefault();
    this.#setZoom(
      this.#zoom() +
        (event.deltaY < 0 ? this.zoomStepValue : -this.zoomStepValue),
    );
  }

  toggleZoom() {
    if (!this.hasImageTarget) return;
    this.#setZoom(this.#zoom() > 1 ? 1 : 2);
  }

  #navigate(direction) {
    const link = this.element.querySelector(`[data-viewer-${direction}]`);
    link?.click();
  }

  #zoom() {
    return Number(this.imageTarget.dataset.zoom) || 1;
  }

  #setZoom(value) {
    const zoom = Math.min(4, Math.max(1, value));
    this.imageTarget.dataset.zoom = zoom;
    this.imageTarget.style.transform = `scale(${zoom})`;
  }
}
