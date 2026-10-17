// Every popup on a phone is the same bottom sheet (the owner's rule,
// 2026-10-17). A menu, a popover or a dropdown panel calls placeAsSheet() from
// its positioning code: on a phone the panel is pinned to the bottom edge,
// full width, marked data-sheet (its markup styles itself from that), over its
// backdrop while open; from lg up it is cleared for its usual anchoring.
const PHONE = "(max-width: 1023.98px)";

export function isPhone() {
  return window.matchMedia(PHONE).matches;
}

export function placeAsSheet(content, backdrop, open) {
  if (!isPhone()) {
    clearSheet(content, backdrop);
    return false;
  }
  content.dataset.sheet = "";
  Object.assign(content.style, {
    position: "fixed",
    left: "0px",
    width: "100vw",
    top: "auto",
    bottom: "0px",
    paddingLeft: "0px",
    paddingRight: "0px",
  });
  // A panel's own max-width (DS::Menu's max_width:) would keep the sheet narrow.
  const panel = content.firstElementChild;
  if (panel) {
    panel.dataset.desktopMaxWidth ??= panel.style.maxWidth;
    panel.style.maxWidth = "none";
  }
  backdrop?.classList.toggle("hidden", !open);
  return true;
}

export function clearSheet(content, backdrop) {
  delete content.dataset.sheet;
  Object.assign(content.style, {
    bottom: "",
    paddingLeft: "",
    paddingRight: "",
  });
  const panel = content.firstElementChild;
  if (panel && panel.dataset.desktopMaxWidth !== undefined) {
    panel.style.maxWidth = panel.dataset.desktopMaxWidth;
    delete panel.dataset.desktopMaxWidth;
  }
  backdrop?.classList.add("hidden");
}

// A backdrop for a popup whose markup has none: made once, inside the host so
// it goes with it, and a tap on it closes the popup.
export function ensureBackdrop(host, onClick) {
  let backdrop = host.querySelector(":scope > [data-sheet-backdrop]");
  if (!backdrop) {
    backdrop = document.createElement("div");
    backdrop.dataset.sheetBackdrop = "";
    backdrop.setAttribute("aria-hidden", "true");
    backdrop.className =
      "hidden fixed inset-0 z-40 bg-overlay backdrop-blur-sm";
    backdrop.addEventListener("click", onClick);
    host.prepend(backdrop);
  }
  return backdrop;
}
