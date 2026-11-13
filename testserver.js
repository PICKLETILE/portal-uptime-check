// Test-only local server. GET /api/build-id answers per the mode in $MODE_FILE: ok | 503 | nobuild | hang.
// POST /alert logs the body to $ALERT_LOG and answers 200; POST /alertfail answers 500. Port is written to $PORT_FILE.
const http = require("http"), fs = require("fs");
const { MODE_FILE, ALERT_LOG, PORT_FILE } = process.env;
http.createServer((req, res) => {
  if (req.method === "POST") {
    let b = ""; req.on("data", d => b += d);
    req.on("end", () => {
      if (req.url === "/alertfail") { res.statusCode = 500; return res.end("boom"); }
      fs.appendFileSync(ALERT_LOG, b + "\n"); res.end("ok");
    });
    return;
  }
  const mode = fs.readFileSync(MODE_FILE, "utf8").trim();
  if (mode === "hang") return;                       // never answers
  if (mode === "503") { res.statusCode = 503; return res.end("Application starting"); }
  if (mode === "nobuild") return res.end("<html>hello</html>");
  res.setHeader("content-type", "application/json"); res.end('{"buildId":"abc123"}');
}).listen(0, "127.0.0.1", function () { fs.writeFileSync(PORT_FILE, String(this.address().port)); });
