/**
 * Translates Mintlify UI strings to Portuguese (pt-BR).
 * Replaces "On this page" with "Nesta página" in the table of contents sidebar.
 * Mintlify may not support topbarLabels.onThisPage in docs.json; this script ensures the translation.
 */
(function () {
  function replaceOnThisPage() {
    var walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_TEXT,
      null,
      false
    );
    var nodes = [];
    while (walker.nextNode()) {
      if (walker.currentNode.textContent.trim() === 'On this page') {
        nodes.push(walker.currentNode);
      }
    }
    nodes.forEach(function (node) {
      node.textContent = 'Nesta página';
    });
  }

  function run() {
    replaceOnThisPage();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
  var attempts = [300, 800, 1500, 3000];
  attempts.forEach(function (delay) {
    setTimeout(run, delay);
  });
  var observer = new MutationObserver(function () {
    run();
  });
  observer.observe(document.body, { childList: true, subtree: true });
})();
