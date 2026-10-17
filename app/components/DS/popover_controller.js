import {
  autoUpdate,
  computePosition,
  flip,
  offset,
  shift,
} from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";
import { placeAsSheet } from "utils/mobile_sheet";

/**
 * Positioned panel for mixed content (forms, pickers, account menus).
 * Mirrors DS--menu's positioning + open/close lifecycle but skips the
 * `role="menu"` / arrow-key navigation that's specific to action lists.
 * Wiring `aria-expanded` on the trigger so AT users hear "expanded" /
 * "collapsed" as the panel opens / closes.
 */
export default class extends Controller {
  static targets = ["button", "content", "backdrop"];

  static values = {
    show: Boolean,
    placement: { type: String, default: "bottom-end" },
    offset: { type: Number, default: 6 },
    mobileFullwidth: { type: Boolean, default: true },
  };

  connect() {
    this.boundUpdate = this.update.bind(this);
    this.addEventListeners();
    this.startAutoUpdate();
  }

  // Derived from the content element's own class rather than tracked as
  // separate state. A Turbo morph (e.g. a same-page refresh while this
  // popover is mounted) re-renders the content element closed without
  // going through toggle()/close(), which would otherwise leave a plain
  // instance property out of sync with the DOM — swallowing the next
  // click because toggle() would think it still needs to close.
  get show() {
    return !this.contentTarget.classList.contains("hidden");
  }

  disconnect() {
    this.removeEventListeners();
    this.stopAutoUpdate();
    this.close();
  }

  addEventListeners() {
    this.buttonTarget.addEventListener("click", this.toggle);
    this.element.addEventListener("keydown", this.handleKeydown);
    document.addEventListener("click", this.handleOutsideClick);
    document.addEventListener("turbo:load", this.handleTurboLoad);
  }

  removeEventListeners() {
    this.buttonTarget.removeEventListener("click", this.toggle);
    this.element.removeEventListener("keydown", this.handleKeydown);
    document.removeEventListener("click", this.handleOutsideClick);
    document.removeEventListener("turbo:load", this.handleTurboLoad);
  }

  handleTurboLoad = () => {
    if (!this.show) this.close();
  };

  handleOutsideClick = (event) => {
    if (this.show && !this.element.contains(event.target)) this.close();
  };

  handleKeydown = (event) => {
    if (event.key === "Escape") {
      this.close();
      this.buttonTarget.focus();
    }
  };

  toggle = () => {
    const nextShow = !this.show;
    this.contentTarget.classList.toggle("hidden", !nextShow);
    this.buttonTarget.setAttribute("aria-expanded", nextShow.toString());
    if (nextShow) {
      this.update();
      this.focusFirstElement();
    } else if (this.hasBackdropTarget) {
      this.backdropTarget.classList.add("hidden");
    }
  };

  close() {
    this.contentTarget.classList.add("hidden");
    this.buttonTarget.setAttribute("aria-expanded", "false");
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden");
  }

  focusFirstElement() {
    const focusableElements =
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';
    const firstFocusableElement =
      this.contentTarget.querySelectorAll(focusableElements)[0];
    if (firstFocusableElement) {
      firstFocusableElement.focus({ preventScroll: true });
    }
  }

  startAutoUpdate() {
    if (!this._cleanup) {
      this._cleanup = autoUpdate(
        this.buttonTarget,
        this.contentTarget,
        this.boundUpdate,
      );
    }
  }

  stopAutoUpdate() {
    if (this._cleanup) {
      this._cleanup();
      this._cleanup = null;
    }
  }

  update() {
    if (!this.buttonTarget || !this.contentTarget) return;

    // A phone gets the bottom sheet every popup shares (2026-10-17).
    if (placeAsSheet(this.contentTarget, this.hasBackdropTarget ? this.backdropTarget : null, this.show)) return;

    computePosition(this.buttonTarget, this.contentTarget, {
      placement: this.placementValue,
      middleware: [offset(this.offsetValue), flip({ padding: 5 }), shift({ padding: 5 })],
      strategy: "fixed",
    }).then(({ x, y }) => {
      Object.assign(this.contentTarget.style, {
        position: "fixed",
        left: `${x}px`,
        top: `${y}px`,
        width: "",
      });
    });
  }
}
