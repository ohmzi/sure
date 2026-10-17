import { Application } from "@hotwired/stimulus";

const application = Application.start();

// Configure Stimulus development experience
application.debug = false;
window.Stimulus = application;

// Show the page-load bar after 120ms rather than 500ms, so a tap is answered
// at once even when the next page takes a moment.
Turbo.config.drive.progressBarDelay = 120;

// Turbo prefetches a link while a mouse hovers it; a phone has no hover, so a
// tap only started loading once the finger lifted. Hand Turbo the same signal
// the moment a finger touches a link, and the page is usually on its way
// before the tap completes. Turbo's own rules still decide (same origin,
// data-turbo-prefetch="false" opts out).
document.addEventListener(
  "touchstart",
  (event) => {
    const link = event.target.closest?.("a[href]");
    if (link) link.dispatchEvent(new MouseEvent("mouseenter"));
  },
  { passive: true, capture: true },
);

Turbo.config.forms.confirm = (data) => {
  const confirmDialogController =
    application.getControllerForElementAndIdentifier(
      document.getElementById("confirm-dialog"),
      "confirm-dialog",
    );

  return confirmDialogController.handleConfirm(data);
};

export { application };
