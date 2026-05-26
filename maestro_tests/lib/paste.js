// runScript helper: set the macOS clipboard to TEXT and fire ⌘V into the
// simulator. Useful for injecting blobs Maestro's inputText doesn't
// handle well (special chars, tabs, multi-line content).
var url = 'http://127.0.0.1:9876/paste?text=' + encodeURIComponent(TEXT);
var response = http.get(url);
output.pasteStatus = response.status || 0;
