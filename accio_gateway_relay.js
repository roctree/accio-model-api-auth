const http = require("node:http");
const fs = require("node:fs");

const HOST = "127.0.0.1";
const PORT = Number(process.env.ACCIO_RELAY_PORT || 18766);
const ORIGINAL_GATEWAY = "https://phoenix-gw.alibaba.com";
const MODEL_BRIDGE = "http://127.0.0.1:18765";
const LOCAL_GATEWAY = "http://127.0.0.1:4097";
const LOCAL_GATEWAY_USERNAME = "phoenix";
const LOCAL_GATEWAY_PASSWORD = process.env.ACCIO_LOCAL_GATEWAY_PASSWORD || "accio-local-7c9f5a4d-2e61-4b87-a0d3-6f4c9182be75";
const LOCAL_GATEWAY_AUTH = LOCAL_GATEWAY_PASSWORD
  ? `Basic ${Buffer.from(`${LOCAL_GATEWAY_USERNAME}:${LOCAL_GATEWAY_PASSWORD}`).toString("base64")}`
  : "";
const MAX_BODY_BYTES = 32 * 1024 * 1024;
const LOG_PATH = process.env.ACCIO_RELAY_LOG || "";

function logRoute(message) {
  if (!LOG_PATH) return;
  try {
    fs.appendFileSync(LOG_PATH, `${new Date().toISOString()} ${message}\n`, "utf8");
  } catch {}
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let bytes = 0;
    const chunks = [];
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > MAX_BODY_BYTES) {
        reject(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

async function forward(request, response, baseUrl) {
  const incomingUrl = new URL(request.url || "/", `http://${HOST}:${PORT}`);
  const targetUrl = `${baseUrl}${incomingUrl.pathname}${incomingUrl.search}`;
  logRoute(`forward ${request.method} ${incomingUrl.pathname} -> ${baseUrl}`);
  const headers = {};
  for (const [name, value] of Object.entries(request.headers)) {
    if (["accept-encoding", "connection", "content-encoding", "content-length", "host", "transfer-encoding"].includes(name)) continue;
    if (value !== undefined) headers[name] = Array.isArray(value) ? value.join(", ") : value;
  }
  if (baseUrl === LOCAL_GATEWAY && LOCAL_GATEWAY_AUTH) headers.authorization = LOCAL_GATEWAY_AUTH;
  const body = ["GET", "HEAD"].includes(request.method || "GET") ? undefined : await readBody(request);
  let upstream;
  try {
    upstream = await fetch(targetUrl, { method: request.method, headers, body });
  } catch (error) {
    logRoute(`error ${request.method} ${incomingUrl.pathname} -> ${baseUrl} ${error?.message || String(error)}`);
    response.writeHead(502, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ error: "ACCIO_GATEWAY_NETWORK", message: error?.message || String(error) }));
    return;
  }
  logRoute(`response ${request.method} ${incomingUrl.pathname} <- ${upstream.status}`);
  const responseHeaders = {};
  for (const [name, value] of upstream.headers) {
    if (["connection", "content-encoding", "content-length", "transfer-encoding"].includes(name)) continue;
    responseHeaders[name] = value;
  }
  response.writeHead(upstream.status, responseHeaders);
  if (upstream.body) {
    for await (const chunk of upstream.body) response.write(chunk);
  }
  response.end();
}

function isHistoryRead(requestUrl, method) {
  if (method !== "GET") return false;
  const pathname = new URL(requestUrl || "/", `http://${HOST}:${PORT}`).pathname;
  return pathname === "/conversation"
    || pathname === "/conversation/active"
    || pathname === "/conversation/search"
    || /^\/conversation\/[^/]+(?:\/checkpoints)?$/.test(pathname)
    || pathname === "/message/paginated"
    || /^\/message\/[^/]+$/.test(pathname)
    || /^\/message\/agent-turn-result\/[^/]+$/.test(pathname);
}

function isLocalRuntimeRequest(requestUrl) {
  const pathname = new URL(requestUrl || "/", `http://${HOST}:${PORT}`).pathname;
  return pathname === "/skills/catalog"
    || pathname === "/skills/installed"
    || pathname === "/skills/picker-catalog"
    || /^\/skills\/[^/]+(?:\/.*)?$/.test(pathname)
    || pathname.startsWith("/skills/install")
    || pathname.startsWith("/skills/local-install")
    || pathname.startsWith("/skills/batch-")
    || pathname.startsWith("/skills/check-updates")
    || pathname.startsWith("/skills/update-all")
    || pathname === "/mcp-servers"
    || pathname.startsWith("/mcp-servers/")
    || pathname === "/mcp"
    || pathname.startsWith("/mcp/")
    || pathname === "/plugins/installed"
    || pathname.startsWith("/plugins/")
    || pathname === "/connectors"
    || pathname.startsWith("/connectors/");
}

function isOriginalRuntimeRequest(requestUrl) {
  const pathname = new URL(requestUrl || "/", `http://${HOST}:${PORT}`).pathname;
  return pathname === "/api/mcp/proxy"
    || pathname === "/api/skill/load"
    || pathname.startsWith("/api/plugin/")
    || pathname.startsWith("/api/tool/")
    || pathname.startsWith("/api/package-skill/")
    || pathname === "/api/channel/query"
    || pathname === "/api/heartbeat/ping";
}

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/healthz") {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ ok: true, modelBridge: MODEL_BRIDGE, originalGateway: ORIGINAL_GATEWAY }));
    return;
  }
  const pathname = new URL(request.url || "/", `http://${HOST}:${PORT}`).pathname;
  const isModelNamespace = pathname === "/api/adk/llm" || pathname.startsWith("/api/adk/llm/");
  const isModelRequest = request.method === "POST" && pathname === "/api/adk/llm/generateContent";
  if (isModelNamespace && !isModelRequest) {
    response.writeHead(405, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ error: "ACCIO_MODEL_ROUTE_BLOCKED", path: pathname }));
    return;
  }
  const isLocalRequest = isLocalRuntimeRequest(request.url);
  const isOriginalRequest = isOriginalRuntimeRequest(request.url);
  if (!isModelRequest && !isHistoryRead(request.url, request.method) && !isLocalRequest && !isOriginalRequest) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("not found");
    return;
  }
  const target = isModelRequest ? MODEL_BRIDGE : isLocalRequest ? LOCAL_GATEWAY : ORIGINAL_GATEWAY;
  logRoute(`route ${request.method} ${pathname} = ${target}`);
  try {
    await forward(request, response, target);
  } catch (error) {
    if (!response.writableEnded) {
      response.writeHead(502, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ error: "ACCIO_RELAY", message: error?.message || String(error) }));
    }
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Accio gateway relay listening on http://${HOST}:${PORT}`);
});
