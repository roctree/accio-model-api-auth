const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

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
const MODEL_CATALOG_PATH = "/api/llm/config/v2";
const MODEL_CACHE_PATH = path.join(os.homedir(), ".accio", "model_cache.json");
const MODEL_LABEL_SEPARATOR = " | Accio: ";
const MODEL_CATALOG_TTL_SECONDS = 5;

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

function getHeader(request, name) {
  const value = request.headers[name];
  return Array.isArray(value) ? value[0] || "" : value || "";
}

function readCachedModelCatalog(request) {
  const cache = JSON.parse(fs.readFileSync(MODEL_CACHE_PATH, "utf8"));
  if (cache.version !== 2 || !cache.snapshots || typeof cache.snapshots !== "object") {
    throw new Error("unsupported Accio model cache format");
  }
  const region = getHeader(request, "x-package-region").trim().toUpperCase();
  const language = getHeader(request, "accept-language").split(",")[0].trim().replace("_", "-").split("-")[0].toLowerCase();
  const cacheKey = `${region}::${language}`;
  const snapshot = cache.snapshots[cacheKey];
  if (!snapshot) throw new Error(`Accio model cache snapshot not found: ${cacheKey}`);
  return JSON.parse(JSON.stringify(snapshot));
}

async function getActualModelStatus() {
  const health = await fetch(`${MODEL_BRIDGE}/healthz`);
  if (!health.ok) throw new Error(`model bridge health check failed: ${health.status}`);
  const status = await health.json();
  if (status.ok !== true || typeof status.model !== "string" || !status.model.trim()) {
    throw new Error("model bridge did not report an active model");
  }
  return status;
}

function stripActualModelLabel(value) {
  const text = typeof value === "string" ? value.trim() : "";
  const separatorIndex = text.indexOf(MODEL_LABEL_SEPARATOR);
  return separatorIndex === -1 ? text : text.slice(separatorIndex + MODEL_LABEL_SEPARATOR.length).trim();
}

function applyActualModelLabel(snapshot, status) {
  if (!Array.isArray(snapshot.data) || !snapshot.ext || !Array.isArray(snapshot.ext.labelList)) {
    throw new Error("invalid Accio model catalog snapshot");
  }
  const model = status.model.trim();
  const reasoningEffort = typeof status.reasoningEffort === "string" ? status.reasoningEffort.trim() : "";
  const actualLabel = reasoningEffort ? `${model} · ${reasoningEffort}` : model;
  const decoratedModelCodes = new Set();
  for (const provider of snapshot.data) {
    if (!Array.isArray(provider.modelList)) continue;
    for (const item of provider.modelList) {
      if (item.visible === false || typeof item.modelCode !== "string" || !item.modelCode.trim()) continue;
      const originalLabel = stripActualModelLabel(item.modelDisplayName) || item.modelCode.trim();
      item.modelDisplayName = `${actualLabel}${MODEL_LABEL_SEPARATOR}${originalLabel}`;
      decoratedModelCodes.add(item.modelCode);
    }
  }
  for (const label of snapshot.ext.labelList) {
    if (!decoratedModelCodes.has(label.targetModelCode)) continue;
    const originalLabel = stripActualModelLabel(label.displayName) || label.targetModelCode;
    label.displayName = `${actualLabel}${MODEL_LABEL_SEPARATOR}${originalLabel}`;
  }
  const baseVersion = String(snapshot.ext.version).split("-actual-")[0];
  snapshot.ext.version = `${baseVersion}-actual-${Buffer.from(actualLabel).toString("base64url")}`;
  snapshot.ext.serverTime = Date.now();
  snapshot.ext.nextChangeAt = null;
  snapshot.ext.ttlSeconds = MODEL_CATALOG_TTL_SECONDS;
  return { snapshot, actualLabel };
}

async function serveModelCatalog(request, response) {
  await readBody(request);
  const snapshot = readCachedModelCatalog(request);
  const status = await getActualModelStatus();
  const catalog = applyActualModelLabel(snapshot, status);
  logRoute(`response POST ${MODEL_CATALOG_PATH} <- 200 actualModel=${catalog.actualLabel}`);
  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
  });
  response.end(JSON.stringify(catalog.snapshot));
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
  const isModelCatalogRequest = request.method === "POST" && pathname === MODEL_CATALOG_PATH;
  if (isModelCatalogRequest) {
    try {
      await serveModelCatalog(request, response);
    } catch (error) {
      logRoute(`error POST ${MODEL_CATALOG_PATH} ${error?.message || String(error)}`);
      response.writeHead(502, { "Content-Type": "application/json; charset=utf-8" });
      response.end(JSON.stringify({ error: "ACCIO_MODEL_CATALOG", message: error?.message || String(error) }));
    }
    return;
  }
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
