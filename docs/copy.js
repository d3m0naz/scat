/* Copy buttons: a <button data-copy="ID"> copies the text of the element
 * with that id (trimmed, without the "$ " prompt, which lives outside it).
 * Uses the Clipboard API, and falls back to a hidden textarea with
 * document.execCommand("copy") where the API is missing or refuses. The
 * label shows "copied" (or "copy failed") for 2 s; an aria-live region
 * announces the result. Buttons stay hidden without JavaScript. */
(function () {
  "use strict";

  if (typeof document === "undefined") return;

  var status = document.getElementById("copy-status");

  function fallback(text) {
    var ta = document.createElement("textarea"), ok = false;
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "0";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  // Calls done(ok) once the text is (or could not be) copied.
  function copy(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { done(true); },
        function () { done(fallback(text)); });
    } else {
      done(fallback(text));
    }
  }

  function setup(btn) {
    var target = document.getElementById(btn.getAttribute("data-copy"));
    var label = btn.textContent, timer = null;
    if (!target) return;
    btn.hidden = false;
    btn.addEventListener("click", function () {
      copy(target.textContent.replace(/\s+$/, ""), function (ok) {
        btn.textContent = ok ? "[ copied ]" : "[ copy failed ]";
        if (status) status.textContent = ok ? "Install command copied." : "Copying failed; select the command by hand.";
        btn.focus();
        clearTimeout(timer);
        timer = setTimeout(function () {
          btn.textContent = label;
          if (status) status.textContent = "";
        }, 2000);
      });
    });
  }

  var buttons = document.querySelectorAll("button[data-copy]"), i;
  for (i = 0; i < buttons.length; i++) setup(buttons[i]);
})();
