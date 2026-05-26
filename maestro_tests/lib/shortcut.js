// runScript helper: send a keystroke to the Simulator via the local
// shortcut-bridge HTTP server.
//
// Required env vars:
//   KEY  — key character or named key (a, p, up, return, ...)
//   MODS — comma-separated modifier list ("cmd", "cmd,shift", "")
var url =
  'http://127.0.0.1:9876/shortcut?key=' + encodeURIComponent(KEY) +
  '&mods=' + encodeURIComponent(MODS || '');
var response = http.get(url);
output.bridgeStatus = response.status || 0;
output.bridgeBody = (response.body || '').toString().trim();
