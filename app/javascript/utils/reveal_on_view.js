// A chart waits off screen as a shimmer of itself, and plays its entrance when
// it scrolls into view (the owner, 2026-10-18: "animate as the user scrolls
// down to them and they are 40% visible; until then a loading state, a nice
// shimmer of the chart"). While pending, the element's own animations are held
// at their start (motion.css: .reveal-pending), so the line draws, the bars
// grow and the slices sweep only once it is seen.
//
// Returns a function that stops watching. Reveals at once when the reader
// asked for less motion, under browser automation, when the browser cannot
// watch, and for an element
// that was already revealed (a redraw after a resize must not shimmer again).

const VISIBLE = 0.4;

export function revealOnView(element) {
  const reveal = () => {
    element.classList.remove("reveal-pending");
    if (element.dataset.revealPosition !== undefined) {
      element.style.position = element.dataset.revealPosition;
      delete element.dataset.revealPosition;
    }
    element.dataset.revealed = "true";
    element.dispatchEvent(new CustomEvent("reveal:shown"));
  };

  // A driven browser (tests, automation) reads charts without scrolling to
  // them, so it gets them at once.
  if (
    element.dataset.revealed === "true" ||
    window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
    navigator.webdriver ||
    !("IntersectionObserver" in window)
  ) {
    element.dataset.revealed = "true";
    return () => {};
  }

  element.classList.add("reveal-pending");
  // The shimmer is laid over the element, which needs to be its box.
  if (getComputedStyle(element).position === "static") {
    element.dataset.revealPosition = element.style.position;
    element.style.position = "relative";
  }

  const observer = new IntersectionObserver(
    (entries) => {
      // 40% of the chart, or 40% of the screen for a chart taller than that.
      const seen = entries.some(
        (entry) =>
          entry.isIntersecting &&
          (entry.intersectionRatio >= VISIBLE ||
            entry.intersectionRect.height >= window.innerHeight * VISIBLE),
      );
      if (!seen) return;
      observer.disconnect();
      reveal();
    },
    { threshold: [0, 0.1, 0.2, 0.3, VISIBLE] },
  );
  observer.observe(element);

  return () => observer.disconnect();
}

// Runs `callback` once the element is revealed (now, if it already is).
export function whenRevealed(element, callback) {
  if (!element.classList.contains("reveal-pending")) {
    callback();
    return;
  }
  element.addEventListener("reveal:shown", callback, { once: true });
}
