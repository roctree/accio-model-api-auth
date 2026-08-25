const http = require("node:http");

const HOST = "127.0.0.1";
const PORT = Number(process.env.ACCIO_OPENCODE_PORT || 18765);
const MODEL = process.env.OPENCODE_GO_MODEL || "deepseek-v4-flash";
const ENDPOINT = process.env.OPENCODE_GO_ENDPOINT || "https://opencode.ai/zen/go/v1/chat/completions";
const AUTH_TYPE = process.env.ACCIO_MODEL_AUTH_TYPE || "api_key";
const REASONING_MODE = process.env.OPENCODE_GO_REASONING_EFFORT || "high";
const ORIGINAL_GATEWAY = (process.env.ACCIO_ORIGINAL_GATEWAY_URL || "https://phoenix-gw.alibaba.com").replace(/\/+$/, "");
const MAX_BODY_BYTES = 32 * 1024 * 1024;
const reasoningByToolCallId = new Map();

if (!["disabled", "low", "high", "max"].includes(REASONING_MODE)) {
  throw new Error(`Unsupported reasoning mode: ${REASONING_MODE}`);
}

function valueOf(object, camel, snake) {
  return object?.[camel] ?? object?.[snake];
}

function parseJson(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function textFromParts(parts) {
  return (Array.isArray(parts) ? parts : [])
    .map((part) => (typeof part?.text === "string" ? part.text : ""))
    .join("");
}

function contentFromParts(parts) {
  const values = [];
  for (const part of Array.isArray(parts) ? parts : []) {
    if (typeof part?.text === "string") {
      values.push({ type: "text", text: part.text });
      continue;
    }
    const inlineData = part?.inlineData ?? part?.inline_data;
    if (inlineData?.data) {
      const mimeType = inlineData.mimeType ?? inlineData.mime_type ?? "application/octet-stream";
      values.push({ type: "image_url", image_url: { url: `data:${mimeType};base64,${inlineData.data}` } });
      continue;
    }
    const fileData = part?.fileData ?? part?.file_data;
    if (fileData?.fileUri ?? fileData?.file_uri) {
      values.push({ type: "image_url", image_url: { url: fileData.fileUri ?? fileData.file_uri } });
    }
  }
  if (values.length === 0) return null;
  if (values.every((value) => value.type === "text")) return values.map((value) => value.text).join("");
  return values;
}

function functionCallFromPart(part) {
  const call = part?.functionCall ?? part?.function_call;
  if (!call) return null;
  const args = call.argsJson ?? call.args_json ?? call.arguments ?? call.args;
  return {
    id: call.id || `call_${Math.random().toString(36).slice(2)}`,
    type: "function",
    function: {
      name: call.name || "",
      arguments: typeof args === "string" ? args : JSON.stringify(args ?? {}),
    },
  };
}

function functionResponseFromPart(part) {
  const response = part?.functionResponse ?? part?.function_response;
  if (!response) return null;
  const value = response.responseJson ?? response.response_json ?? response.response;
  return {
    role: "tool",
    tool_call_id: response.id || response.name || "",
    content: typeof value === "string" ? value : JSON.stringify(value ?? {}),
  };
}

function messagesFromContents(contents) {
  const messages = [];
  for (const content of Array.isArray(contents) ? contents : []) {
    const role = content?.role === "model" ? "assistant" : content?.role === "function" ? "tool" : content?.role || "user";
    const parts = Array.isArray(content?.parts) ? content.parts : [];
    const toolResponses = parts.map(functionResponseFromPart).filter(Boolean);
    if (toolResponses.length > 0) {
      messages.push(...toolResponses);
      continue;
    }
    const toolCalls = parts.map(functionCallFromPart).filter(Boolean);
    const text = contentFromParts(parts);
    if (toolCalls.length > 0 || text !== null) {
      const reasoningContent = toolCalls
        .map((call) => reasoningByToolCallId.get(call.id))
        .find((value) => typeof value === "string" && value.length > 0);
      messages.push({
        role,
        content: text,
        ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
        ...(reasoningContent ? { reasoning_content: reasoningContent } : {}),
      });
    }
  }
  return messages;
}

function systemMessage(instruction) {
  if (!instruction) return null;
  if (typeof instruction === "string") return { role: "system", content: instruction };
  if (Array.isArray(instruction?.parts)) {
    const content = textFromParts(instruction.parts);
    return content ? { role: "system", content } : null;
  }
  return null;
}

function normalizeToolDeclaration(declaration) {
  const functionDeclaration = declaration?.function ?? declaration?.functionDeclaration ?? declaration?.function_declaration ?? declaration;
  const parameters = parseJson(
    functionDeclaration?.parameters ?? functionDeclaration?.parametersJson ?? functionDeclaration?.parameters_json,
    { type: "object", properties: {} },
  );
  if (!functionDeclaration?.name) return null;
  return {
    type: "function",
    function: {
      name: functionDeclaration.name,
      description: functionDeclaration.description || "",
      parameters,
    },
  };
}

function openAiTools(tools) {
  const normalized = [];
  for (const tool of Array.isArray(tools) ? tools : []) {
    const declarations = tool?.functionDeclarations ?? tool?.function_declarations;
    if (Array.isArray(declarations)) {
      for (const declaration of declarations) {
        const item = normalizeToolDeclaration(declaration);
        if (item) normalized.push(item);
      }
      continue;
    }
    const item = normalizeToolDeclaration(tool);
    if (item) normalized.push(item);
  }
  return normalized;
}

function openAiToolChoice(choice) {
  if (choice === undefined || choice === null || choice === "") return undefined;
  if (typeof choice === "string") {
    const normalized = choice.toLowerCase();
    if (normalized === "auto") return "auto";
    if (normalized === "none") return "none";
    if (normalized === "any" || normalized === "required") return "auto";
  }
  const functionChoice = choice?.functionCall ?? choice?.function_call ?? choice?.function;
  if (functionChoice?.name) return { type: "function", function: { name: functionChoice.name } };
  return undefined;
}

function toOpenAiRequest(payload) {
  const contents = valueOf(payload, "contents", "contents") || [];
  const instruction = valueOf(payload, "systemInstruction", "system_instruction");
  const tools = openAiTools(valueOf(payload, "tools", "tools"));
  const request = {
    model: MODEL,
    messages: [systemMessage(instruction), ...messagesFromContents(contents)].filter(Boolean),
    stream: true,
    stream_options: { include_usage: true },
  };
  const temperature = valueOf(payload, "temperature", "temperature");
  const maxTokens = valueOf(payload, "maxOutputTokens", "max_output_tokens");
  const topP = valueOf(payload, "topP", "top_p");
  const stop = valueOf(payload, "stopSequences", "stop_sequences");
  if (temperature !== undefined) request.temperature = temperature;
  if (maxTokens !== undefined) request.max_tokens = maxTokens;
  if (topP !== undefined) request.top_p = topP;
  if (Array.isArray(stop) && stop.length > 0) request.stop = stop;
  request.thinking = { type: REASONING_MODE === "disabled" ? "disabled" : "enabled" };
  if (REASONING_MODE !== "disabled") request.reasoning_effort = REASONING_MODE;
  if (tools.length > 0) {
    request.tools = tools;
    const toolChoice = openAiToolChoice(valueOf(payload, "toolChoice", "tool_choice"));
    if (toolChoice !== undefined) request.tool_choice = toolChoice;
  }
  const responseFormat = valueOf(payload, "responseFormat", "response_format");
  if (responseFormat) request.response_format = responseFormat;
  return request;
}

async function* sseData(body) {
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    const events = buffer.split(/\r\n\r\n|\n\n|\r\r/);
    buffer = events.pop() || "";
    for (const event of events) {
      const data = event
        .split(/\r\n|\n|\r/)
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).replace(/^ /, ""))
        .join("\n");
      if (data) yield data;
    }
  }
  const data = buffer
    .split(/\r\n|\n|\r/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).replace(/^ /, ""))
    .join("\n");
  if (data) yield data;
}

function sendFrame(response, frame) {
  response.write(`data: ${JSON.stringify(frame)}\n\n`);
}

function errorFrame(response, errorCode, errorMessage) {
  sendFrame(response, {
    content: { role: "model", parts: [{ text: "" }] },
    turnComplete: true,
    partial: false,
    errorCode: String(errorCode),
    errorMessage: String(errorMessage),
  });
  response.end();
}

function usageMetadata(usage) {
  if (!usage) return undefined;
  return {
    promptTokenCount: usage.prompt_tokens,
    candidatesTokenCount: usage.completion_tokens,
    totalTokenCount: usage.total_tokens,
  };
}

async function proxy(request, response, payload) {
  const apiKey = process.env.OPENCODE_GO_API_KEY;
  if (AUTH_TYPE === "api_key" && !apiKey) {
    errorFrame(response, "CONFIG", "OPENCODE_GO_API_KEY is not set");
    return;
  }
  if (AUTH_TYPE !== "api_key" && AUTH_TYPE !== "none") {
    errorFrame(response, "CONFIG", `Unsupported authentication type: ${AUTH_TYPE}`);
    return;
  }
  const upstreamRequest = toOpenAiRequest(payload);
  const headers = {
    "Content-Type": "application/json",
    Accept: "text/event-stream",
  };
  if (AUTH_TYPE === "api_key") headers.Authorization = `Bearer ${apiKey}`;
  let upstream;
  try {
    upstream = await fetch(ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify(upstreamRequest),
      signal: request.signal,
    });
  } catch (error) {
    errorFrame(response, "UPSTREAM_NETWORK", error?.message || String(error));
    return;
  }
  if (!upstream.ok) {
    const body = await upstream.text().catch(() => "");
    let message = body.slice(0, 800);
    try {
      const parsed = JSON.parse(body);
      message = parsed?.error?.message || parsed?.message || message;
    } catch {}
    errorFrame(response, `UPSTREAM_HTTP_${upstream.status}`, message || upstream.statusText);
    return;
  }
  if (!upstream.body) {
    errorFrame(response, "UPSTREAM_EMPTY", "Model API returned an empty response body");
    return;
  }

  const toolCalls = new Map();
  let sawOutput = false;
  let responseId;
  let usage;
  let finishReason;
  let reasoningContent = "";
  for await (const data of sseData(upstream.body)) {
    if (data === "[DONE]") continue;
    let chunk;
    try {
      chunk = JSON.parse(data);
    } catch {
      continue;
    }
    responseId ||= chunk.id;
    usage ||= usageMetadata(chunk.usage);
    const choice = chunk.choices?.[0];
    const delta = choice?.delta;
    finishReason ||= choice?.finish_reason;
    if (typeof delta?.reasoning_content === "string") {
      reasoningContent += delta.reasoning_content;
    }
    if (typeof delta?.content === "string" && delta.content.length > 0) {
      sawOutput = true;
      sendFrame(response, {
        content: { role: "model", parts: [{ text: delta.content }] },
        partial: true,
        turnComplete: false,
        customMetadata: { model: MODEL, reasoning_effort: REASONING_MODE, response_id: responseId },
      });
    }
    for (const call of Array.isArray(delta?.tool_calls) ? delta.tool_calls : []) {
      const index = call.index ?? toolCalls.size;
      const current = toolCalls.get(index) || { id: "", name: "", arguments: "" };
      if (call.id) current.id = call.id;
      if (call.function?.name) current.name += call.function.name;
      if (call.function?.arguments) current.arguments += call.function.arguments;
      toolCalls.set(index, current);
    }
  }
  const parts = [...toolCalls.values()].map((call) => ({
    functionCall: {
      id: call.id,
      name: call.name,
      argsJson: call.arguments || "{}",
    },
  }));
  if (parts.length > 0) {
    sawOutput = true;
    if (reasoningContent) {
      for (const call of toolCalls.values()) {
        if (call.id) reasoningByToolCallId.set(call.id, reasoningContent);
      }
      while (reasoningByToolCallId.size > 256) {
        reasoningByToolCallId.delete(reasoningByToolCallId.keys().next().value);
      }
    }
  }
  sendFrame(response, {
    content: parts.length > 0
      ? { role: "model", parts }
      : sawOutput
        ? { role: "model", parts: [] }
        : { role: "model", parts: [{ text: "" }] },
    partial: false,
    turnComplete: true,
    finishReason: finishReason || "STOP",
    usageMetadata: usage,
    customMetadata: { model: MODEL, reasoning_effort: REASONING_MODE, response_id: responseId },
  });
  response.end();
}

function readJson(request) {
  return readBody(request).then((body) => JSON.parse(body.toString("utf8")));
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
    request.on("end", () => {
      resolve(Buffer.concat(chunks));
    });
    request.on("error", reject);
  });
}

async function forwardGateway(request, response) {
  const incomingUrl = new URL(request.url || "/", `http://${HOST}:${PORT}`);
  const targetUrl = `${ORIGINAL_GATEWAY}${incomingUrl.pathname}${incomingUrl.search}`;
  const headers = {};
  for (const [name, value] of Object.entries(request.headers)) {
    if (["accept-encoding", "connection", "content-encoding", "content-length", "host", "transfer-encoding"].includes(name)) continue;
    if (value !== undefined) headers[name] = Array.isArray(value) ? value.join(", ") : value;
  }
  const body = ["GET", "HEAD"].includes(request.method || "GET") ? undefined : await readBody(request);
  let upstream;
  try {
    upstream = await fetch(targetUrl, { method: request.method, headers, body });
  } catch (error) {
    response.writeHead(502, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ error: "ACCIO_GATEWAY_NETWORK", message: error?.message || String(error) }));
    return;
  }
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

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/healthz") {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ ok: true, model: MODEL, endpoint: ENDPOINT, authType: AUTH_TYPE, reasoningEffort: REASONING_MODE, apiKeyConfigured: Boolean(process.env.OPENCODE_GO_API_KEY) }));
    return;
  }
  if (request.url?.startsWith("/api/adk/llm/generateContent") && request.method === "POST") {
    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    });
    try {
      await proxy(request, response, await readJson(request));
    } catch (error) {
      if (!response.writableEnded) errorFrame(response, "ADAPTER_REQUEST", error?.message || String(error));
    }
    return;
  }
  if (request.url?.startsWith("/api/")) {
    await forwardGateway(request, response);
    return;
  }
  if (request.method !== "POST" || !request.url?.startsWith("/api/adk/llm/generateContent")) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("not found");
    return;
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Accio model bridge listening on http://${HOST}:${PORT}`);
  console.log(`model=${MODEL}`);
  console.log(`authType=${AUTH_TYPE}`);
  console.log(`reasoningEffort=${REASONING_MODE}`);
  console.log(`originalGateway=${ORIGINAL_GATEWAY}`);
  console.log(`apiKeyConfigured=${Boolean(process.env.OPENCODE_GO_API_KEY)}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
