// Minimal, dependency-free static server for the built 28 LEND app (web/dist).
// Isolated pm2 process — does not touch Caddy/vaultlens. Port via PORT env (default 3458).
const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "dist");
const PORT = Number(process.env.PORT || 3458);
const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css",
  ".svg": "image/svg+xml", ".json": "application/json", ".ico": "image/x-icon",
  ".png": "image/png", ".woff2": "font/woff2", ".map": "application/json",
};

http
  .createServer((req, res) => {
    let p = decodeURIComponent((req.url || "/").split("?")[0]);
    if (p === "/") p = "/index.html";
    const file = path.normalize(path.join(ROOT, p));
    if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end("forbidden"); } // traversal guard
    fs.readFile(file, (err, data) => {
      if (err) {
        // single-page app: fall back to index.html
        return fs.readFile(path.join(ROOT, "index.html"), (e2, idx) => {
          if (e2) { res.writeHead(404); return res.end("not found"); }
          res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
          res.end(idx);
        });
      }
      const type = TYPES[path.extname(file)] || "application/octet-stream";
      const cache = file.includes(`${path.sep}assets${path.sep}`) ? "public,max-age=31536000,immutable" : "no-cache";
      res.writeHead(200, { "content-type": type, "cache-control": cache });
      res.end(data);
    });
  })
  .listen(PORT, () => console.log(`28 LEND web serving ./dist on :${PORT}`));
