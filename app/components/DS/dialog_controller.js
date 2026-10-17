import { Controller } from "@hotwired/stimulus";

const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "textarea:not([disabled])",
  "input:not([disabled]):not([type=hidden])",
  "select:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(", ");

// Where focus goes back to, left by a dialog replaced while still open for the
// one that takes its place in the same frame.
const returnFocusByFrame = new WeakMap();

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["content", "grabber"]

  static values = {
    autoOpen: { type: Boolean, default: false },
    reloadOnClose: { type: Boolean, default: false },
    disableClickOutside: { type: Boolean, default: false },
    // The iOS bottom sheet (DS::Dialog variant: "sheet"): opened on demand by
    // a `sheet:open` event, closed by sliding away, dragged down to dismiss.
    sheet: { type: Boolean, default: false },
  };

  connect() {
    this._priorFocus = null;
    this._frame = this.element.closest("turbo-frame");
    this._onKeydown = this.#onKeydown.bind(this);
    this._onClose = this.#onClose.bind(this);

    this._onCancel = this.#onCancel.bind(this);

    this.element.addEventListener("keydown", this._onKeydown);
    this.element.addEventListener("close", this._onClose);
    this.element.addEventListener("cancel", this._onCancel);

    // A sheet cached mid-slide (navigated away during its close) must not come
    // back invisible or offset.
    if (this.sheetValue) this.#resetSheetStyles();

    if (this.element.matches(":modal")) return;
    // Back restores a dialog cached open as a plain open one: no backdrop, no
    // focus trap. Put it back as it was rendered, closed and with no close
    // event for listeners to act on, and let auto-open show it as a modal.
    if (this.element.open) this.element.removeAttribute("open");
    if (this.autoOpenValue) {
      this._priorFocus = this.#returnFocusTarget();
      this.element.showModal();
      this.#focusInitial();
    }
  }

  disconnect() {
    this.element.removeEventListener("keydown", this._onKeydown);
    this.element.removeEventListener("close", this._onClose);
    this.element.removeEventListener("cancel", this._onCancel);
    this.#unlockScroll();

    // Replaced while still open: one drawer linking to the next inside the
    // same frame. The link that did it left with this dialog, so focus would
    // fall to <body> on close. The dialog connecting in its place, in this
    // same mutation batch, inherits the way back instead.
    if (this._priorFocus && this._frame) {
      const frame = this._frame;
      returnFocusByFrame.set(frame, this._priorFocus);
      queueMicrotask(() => returnFocusByFrame.delete(frame));
    }
  }

  // If the user clicks anywhere outside of the visible content, close the dialog
  clickOutside(e) {
    if (this.disableClickOutsideValue) return;
    if (!this.contentTarget.contains(e.target)) {
      this.close();
    }
  }

  // Open on demand (a sheet rendered inline in the page, never auto-opened).
  open() {
    if (this.element.open) return;
    this._priorFocus = this.#returnFocusTarget();
    this.element.showModal();
    if (this.sheetValue) this.#lockScroll();
    this.#focusInitial();
  }

  close() {
    if (this.sheetValue && this.element.open && !this.#reducedMotion()) {
      this.#slideAway();
      return;
    }
    this.#finishClose();
  }

  // Drag the grabber down: the sheet follows the finger; let go far enough
  // (or with a flick) and it leaves, otherwise it springs back.
  dragStart(event) {
    if (!this.sheetValue || !this.hasContentTarget) return;
    const content = this.contentTarget;
    const startY = event.clientY;
    const startTime = performance.now();
    let offset = 0;
    content.style.transition = "none";
    this.grabberTarget.setPointerCapture?.(event.pointerId);

    const move = (moveEvent) => {
      offset = Math.max(0, moveEvent.clientY - startY);
      content.style.transform = `translateY(${offset}px)`;
    };
    const end = () => {
      this.grabberTarget.removeEventListener("pointermove", move);
      this.grabberTarget.removeEventListener("pointerup", end);
      this.grabberTarget.removeEventListener("pointercancel", end);
      content.style.transition = "";
      const velocity = offset / Math.max(1, performance.now() - startTime);
      if (offset > content.offsetHeight * 0.25 || velocity > 0.6) {
        this.close();
      } else {
        content.style.transform = "";
      }
    };
    this.grabberTarget.addEventListener("pointermove", move);
    this.grabberTarget.addEventListener("pointerup", end);
    this.grabberTarget.addEventListener("pointercancel", end);
  }

  #finishClose() {
    this.element.close();
    if (this.sheetValue) this.#resetSheetStyles();
    // Now as well as on the close event: a reload-on-close visit can cache
    // the page before that event fires.
    this.#clearParentModalFrame();

    if (this.reloadOnCloseValue) {
      Turbo.visit(window.location.href);
    }
  }

  // Whatever had focus as this opened, unless that went with the dialog this
  // one replaced.
  #returnFocusTarget() {
    const active = document.activeElement;
    if (active && active !== document.body) return active;
    return returnFocusByFrame.get(this._frame) ?? active;
  }

  // Move focus to the first focusable child unless the dialog already
  // declared one via the autofocus attribute. Native `<dialog>.showModal()`
  // is supposed to do this but the behavior varies across engines.
  #focusInitial() {
    if (this.element.querySelector("[autofocus]")) return;
    this.#focusables()[0]?.focus();
  }

  // Tab/Shift+Tab wrap inside the dialog so focus can't leak to the page
  // behind. Without this an a11y user can tab into the backdrop'd content
  // and lose the modal context entirely.
  #onKeydown(e) {
    if (e.key !== "Tab") return;
    const focusables = this.#focusables();
    if (focusables.length === 0) {
      e.preventDefault();
      return;
    }
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  // Slide the sheet off the bottom edge (fade it as a panel from lg), then
  // close it for real. One close at a time; a timer covers a lost
  // transitionend.
  #slideAway() {
    if (this._closing) return;
    this._closing = true;
    const content = this.contentTarget;
    const finish = (event) => {
      // transitionend bubbles from the sheet's own children (chips, rows).
      if (event && event.target !== content) return;
      if (!this._closing) return;
      this._closing = false;
      content.removeEventListener("transitionend", finish);
      this.#finishClose();
    };
    content.addEventListener("transitionend", finish);
    setTimeout(finish, 350);
    if (window.matchMedia("(min-width: 1024px)").matches) {
      content.style.opacity = "0";
      content.style.transform = "scale(0.95)";
    } else {
      content.style.transform = "translateY(100%)";
    }
  }

  #resetSheetStyles() {
    if (!this.hasContentTarget) return;
    const content = this.contentTarget;
    content.style.transform = "";
    content.style.opacity = "";
    content.style.transition = "";
  }

  // Escape on a sheet slides it away instead of snapping it shut.
  #onCancel(event) {
    if (!this.sheetValue || this.#reducedMotion()) return;
    event.preventDefault();
    this.close();
  }

  #reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  // A sheet holds the page still behind it: the app scrolls in #main, and
  // iOS scrolls the document through the backdrop.
  #lockScroll() {
    this._scrollLocked = [document.documentElement, document.getElementById("main")]
      .filter(Boolean)
      .map((element) => [element, element.style.overflow]);
    for (const [element] of this._scrollLocked) element.style.overflow = "hidden";
  }

  #unlockScroll() {
    for (const [element, overflow] of this._scrollLocked ?? []) element.style.overflow = overflow;
    this._scrollLocked = null;
  }

  #onClose() {
    this.#unlockScroll();
    const prior = this._priorFocus;
    this._priorFocus = null;
    if (prior && typeof prior.focus === "function" && document.body.contains(prior)) {
      prior.focus();
    }
    // Escape closes the dialog natively, without close().
    this.#clearParentModalFrame();
  }

  #focusables() {
    return Array.from(this.element.querySelectorAll(FOCUSABLE_SELECTOR)).filter(
      (el) => el.offsetParent !== null || el === document.activeElement,
    );
  }

  // When the dialog lives inside a top-level <turbo-frame id="modal">,
  // emptying the frame on close stops Turbo's page cache from snapshotting
  // an open dialog and reopening it on browser back.
  #clearParentModalFrame() {
    const frame = this.element.closest('turbo-frame[id="modal"]');
    if (frame) frame.innerHTML = "";
  }
}
