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
      "hidden fixed inset-0 z-40 bg-overlay backdrop-blur-sm transition-opacity duration-300 starting:opacity-0 motion-reduce:transition-none";
    backdrop.addEventListener("click", onClick);
    host.prepend(backdrop);
  }
  return backdrop;
}

// Sheets come and go like iOS's (the owner, 2026-10-19): in on a settling
// curve (the panels' own classes), out quicker and speeding up, the backdrop
// fading with them, and a grabber that drags them down.
const LEAVE = { duration: 240, easing: "cubic-bezier(0.4, 0, 1, 1)" };

function reducedMotion() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// Slides an open sheet off the bottom edge and fades its backdrop, then calls
// `done` to hide them for real. Anything not showing as a sheet is done at
// once.
export function dismissSheet(content, backdrop, done) {
  const panel = content.firstElementChild || content;
  if (
    content.dataset.sheet === undefined ||
    content.classList.contains("hidden") ||
    reducedMotion()
  ) {
    done();
    return;
  }
  if (content.dataset.sheetLeaving) return;
  content.dataset.sheetLeaving = "";

  const from = getComputedStyle(panel).transform;
  const slide = panel.animate(
    [
      { transform: from === "none" ? "translateY(0)" : from },
      { transform: "translateY(100%)" },
    ],
    { ...LEAVE, fill: "forwards" },
  );
  backdrop?.animate(
    [{ opacity: getComputedStyle(backdrop).opacity }, { opacity: 0 }],
    {
      ...LEAVE,
      fill: "forwards",
    },
  );
  slide.finished
    .catch(() => {})
    .then(() => {
      delete content.dataset.sheetLeaving;
      done();
      for (const animation of [
        ...panel.getAnimations(),
        ...(backdrop?.getAnimations() ?? []),
      ])
        animation.cancel();
      panel.style.transform = "";
    });
}

// Lets the sheet's grabber ([data-sheet-grabber]) drag it down: it follows
// the finger, the backdrop lightens, and a long enough drag or a flick calls
// `onDismiss`; otherwise it springs back. Bound once per sheet.
export function bindSheetDrag(content, backdrop, onDismiss) {
  if (content.dataset.sheetDragBound) return;
  content.dataset.sheetDragBound = "";
  const panel = content.firstElementChild || content;

  content.addEventListener("pointerdown", (event) => {
    const grabber = event.target.closest("[data-sheet-grabber]");
    if (!grabber || content.dataset.sheet === undefined) return;
    event.preventDefault();
    grabber.setPointerCapture?.(event.pointerId);
    const startY = event.clientY;
    let lastY = startY;
    let lastTime = performance.now();
    let velocity = 0;
    let offset = 0;
    panel.style.transition = "none";

    const move = (moveEvent) => {
      const now = performance.now();
      velocity = (moveEvent.clientY - lastY) / Math.max(1, now - lastTime);
      lastY = moveEvent.clientY;
      lastTime = now;
      offset = Math.max(0, moveEvent.clientY - startY);
      panel.style.transform = `translateY(${offset}px)`;
      if (backdrop)
        backdrop.style.opacity = String(
          Math.max(0, 1 - (offset / panel.offsetHeight) * 1.4),
        );
    };
    const end = () => {
      grabber.removeEventListener("pointermove", move);
      grabber.removeEventListener("pointerup", end);
      grabber.removeEventListener("pointercancel", end);
      panel.style.transition = "";
      if (offset > panel.offsetHeight * 0.25 || velocity > 0.5) {
        onDismiss();
        if (backdrop) backdrop.style.opacity = "";
      } else {
        panel.style.transform = "";
        if (backdrop) backdrop.style.opacity = "";
      }
    };
    grabber.addEventListener("pointermove", move);
    grabber.addEventListener("pointerup", end);
    grabber.addEventListener("pointercancel", end);
  });
}
