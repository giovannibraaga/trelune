// Trelune MCP server for the Docker container (works with the Mac app closed).
//   node server.mjs --stdio   one MCP session over stdio (started by `docker exec -i`)
//   node server.mjs --daemon  keeps the container alive and syncs cloud schedules every minute
// Shares the app's data folder (mounted at DATA_DIR): publications.json, assistant.json, workspace.json…
// Outbound traffic goes through the egress proxy, which only allows the providers' API hosts.
import { readFileSync, writeFileSync, renameSync, mkdirSync, rmdirSync, statSync, existsSync } from "node:fs";
import { createHash, createHmac, randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { extname, basename } from "node:path";

const DATA = process.env.DATA_DIR ?? "/data";
const FILES = { posts: `${DATA}/publications.json`, lock: `${DATA}/.publications.lockdir`, assistant: `${DATA}/assistant.json`, log: `${DATA}/assistant-log.json`, workspace: `${DATA}/workspace.json`, aws: `${DATA}/mcp-aws.json`, tombstones: `${DATA}/cloud-cancel.json` };
const NETWORKS = ["YouTube", "Instagram", "Facebook", "TikTok", "Threads", "X"];
const STATUS = { draft: "Rascunho", scheduled: "Agendado", publishing: "Publicando", published: "Publicado", partial: "Parcial", failed: "Falhou" };
// Cloud targets: env vars win; otherwise they come from mcp-aws.json, which the Mac app writes with the
// account of the configured key and the resource prefix chosen in Ajustes (see cloud/deploy.sh).
const cloudTarget = () => {
  const c = readJSON(`${DATA}/mcp-aws.json`, {}) ?? {};
  const prefix = c.resourcePrefix || "trelune", region = c.region || "us-east-1";
  const functionArn = process.env.FUNCTION_ARN || c.functionArn || (c.account && `arn:aws:lambda:${region}:${c.account}:function:${prefix}-publisher`);
  const roleArn = process.env.SCHEDULER_ROLE_ARN || c.roleArn || (c.account && `arn:aws:iam::${c.account}:role/${prefix}-scheduler`);
  if (!functionArn || !roleArn) throw new Error("Conta AWS desconhecida: abra o Trelune com a publicação pela nuvem ativa ou defina FUNCTION_ARN e SCHEDULER_ROLE_ARN.");
  return { functionArn, roleArn };
};
const VIDEO = new Set([".mp4", ".mov", ".m4v", ".webm"]), IMAGE = new Set([".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic"]);
const MIME = { ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp", ".heic": "image/heic", ".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm" };

// Swift's JSONEncoder stores Date as seconds since 2001-01-01.
const EPOCH = 978307200;
const toSwift = (date) => date.getTime() / 1000 - EPOCH;
const fromSwift = (value) => new Date((value + EPOCH) * 1000);
class Issue extends Error {}
const readJSON = (file, fallback) => { try { return JSON.parse(readFileSync(file, "utf8")); } catch { return fallback; } };
const writeJSON = (file, value) => { const temp = `${file}.${process.pid}.tmp`; writeFileSync(temp, JSON.stringify(value, null, 2)); renameSync(temp, file); };
const workspace = () => readJSON(FILES.workspace, {});
const timeZone = () => workspace().timeZone ?? "America/Sao_Paulo";
const formatLocal = (date) => new Intl.DateTimeFormat("pt-BR", { timeZone: timeZone(), dateStyle: "medium", timeStyle: "short" }).format(date);
const iso = (date) => {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: timeZone(), year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23", timeZoneName: "longOffset" }).formatToParts(date).map((p) => [p.type, p.value]));
  const offset = parts.timeZoneName.replace("GMT", "") || "+00:00";
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${offset}`;
};

// ---------- shared store (same lock directory as the app) ----------
async function withLock(body) {
  let owned = false;
  for (let i = 0; i < 100 && !owned; i++) {
    try { mkdirSync(FILES.lock); owned = true; }
    catch {
      try { if (Date.now() - statSync(FILES.lock).birthtimeMs > 30_000) { rmdirSync(FILES.lock); continue; } } catch {}
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  try { return await body(); } finally { if (owned) try { rmdirSync(FILES.lock); } catch {} }
}
const loadPosts = () => readJSON(FILES.posts, []);
async function mutate(change) {
  return withLock(async () => { const posts = loadPosts(); const result = await change(posts); writeJSON(FILES.posts, posts); return result; });
}
const settings = () => ({ enabled: false, allowWrite: true, allowSchedule: false, allowDelete: false, ...readJSON(FILES.assistant, {}) });
function log(tool, ok, summary) {
  const items = readJSON(FILES.log, []);
  items.unshift({ id: randomUUID().toUpperCase(), date: toSwift(new Date()), tool, ok, summary: `[Docker] ${summary}` });
  writeJSON(FILES.log, items.slice(0, 200));
}

// ---------- publication helpers (mirror Publication in Models.swift) ----------
const kind = (path) => VIDEO.has(extname(path).toLowerCase()) ? "video" : IMAGE.has(extname(path).toLowerCase()) ? "image" : "other";
const textFor = (post, network) => (post.overrides?.[network] ?? "").trim() ? post.overrides[network] : post.text;
const titleFor = (post, network) => (post.titles?.[network] ?? "").trim() ? post.titles[network] : post.title;
function format(post, network) {
  const images = post.media.filter((m) => kind(m) === "image").length, videos = post.media.filter((m) => kind(m) === "video").length;
  if (!post.media.length) return network === "YouTube" ? "Vídeo" : "Texto";
  if (videos === 1 && images === 0) return { Instagram: "Reels", Facebook: "Reel" }[network] ?? "Vídeo";
  if (images === 1 && videos === 0) return network === "TikTok" ? "Fotos" : ["Instagram", "Facebook"].includes(network) ? "Post" : "Imagem";
  return { TikTok: `Fotos · ${post.media.length}`, X: `Imagens · ${post.media.length}`, Facebook: `Álbum · ${post.media.length}` }[network] ?? `Carrossel · ${post.media.length}`;
}
function encode(post) {
  const value = { id: post.id, title: post.title, text: post.text, platforms: post.platforms, status: post.status, date: iso(fromSwift(post.date)), date_local: formatLocal(fromSwift(post.date)), youtube_privacy: post.youtubePrivacy ?? "private", stories: post.stories !== false };
  if (post.media?.length) { value.media_paths = post.media; value.formats = Object.fromEntries(post.platforms.map((n) => [n, format(post, n)])); }
  if (Object.keys(post.titles ?? {}).length) value.titles = post.titles;
  if (post.publicMediaURL) value.public_media_url = post.publicMediaURL;
  if (Object.keys(post.overrides ?? {}).length) value.overrides = post.overrides;
  if (Object.keys(post.results ?? {}).length) value.results = Object.fromEntries(Object.entries(post.results).map(([k, r]) => [k, { state: r.state, detail: r.detail, link: r.link ?? "" }]));
  if (post.cloud) value.cloud = "agendado na nuvem (publica com o Mac desligado)";
  return value;
}
function find(posts, args) {
  const post = posts.find((p) => p.id.toUpperCase() === String(args.id ?? "").toUpperCase());
  if (!post) throw new Issue("Publicação não encontrada. Use list_publications para obter o id.");
  return post;
}
function platformsArg(value) {
  if (!Array.isArray(value) || !value.length) throw new Issue("Informe pelo menos um destino em platforms.");
  for (const item of value) if (!NETWORKS.includes(item)) throw new Issue(`Rede desconhecida: ${item}. Use ${NETWORKS.join(", ")}.`);
  return [...new Set(value)];
}
function mediaPath(path) {
  const expanded = path.replace(/^~(?=\/)/, process.env.HOST_HOME ?? "");
  if (!existsSync(expanded)) throw new Issue(`Arquivo de mídia não encontrado (ou fora das pastas compartilhadas com o Docker): ${path}`);
  return expanded;
}
function apply(args, post) {
  if (typeof args.media_path === "string") post.media = args.media_path ? [mediaPath(args.media_path), ...post.media.slice(1)] : [];
  if (Array.isArray(args.media_paths)) post.media = args.media_paths.map(mediaPath);
  for (const field of ["titles", "overrides"]) {
    if (args[field] && typeof args[field] === "object") {
      for (const key of Object.keys(args[field])) if (!NETWORKS.includes(key)) throw new Issue(`Rede desconhecida em ${field}: ${key}`);
      post[field] = args[field];
    }
  }
  if (typeof args.public_media_url === "string") { if (args.public_media_url && !args.public_media_url.startsWith("https://")) throw new Issue("public_media_url precisa ser HTTPS."); post.publicMediaURL = args.public_media_url || undefined; }
  if (args.youtube_privacy) { if (!["private", "unlisted", "public"].includes(args.youtube_privacy)) throw new Issue("youtube_privacy inválido."); post.youtubePrivacy = args.youtube_privacy; }
  if (typeof args.stories === "boolean") post.stories = args.stories;
}
function parseDate(raw) {
  if (typeof raw !== "string") return null;
  let value = raw;
  if (!/[zZ]|[+-]\d\d:?\d\d$/.test(raw)) {
    // No offset: interpret in the workspace time zone.
    const guess = new Date(`${raw}Z`);
    if (isNaN(guess)) return null;
    const offset = iso(guess).slice(19);
    value = `${raw}${offset}`;
  }
  const date = new Date(value);
  return isNaN(date) ? null : date;
}

// ---------- AWS (SigV4, no SDK) ----------
const awsConfig = () => { const config = readJSON(FILES.aws, null); return config?.accessKey && config?.secretKey ? config : null; };
const sha = (data) => createHash("sha256").update(data).digest("hex");
const hmac = (key, text) => createHmac("sha256", key).update(text).digest();
const enc = (value, keepSlash) => encodeURIComponent(value).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`).replace(keepSlash ? /%2F/g : /$^/, "/");
async function aws(method, { service, host, path = "/", query = {}, body, payloadHash, headers = {} }) {
  const config = awsConfig();
  if (!config) throw new Issue("A nuvem não está configurada para o MCP. Abra o app, configure a hospedagem S3 e ligue “Publicar pela nuvem”.");
  const amz = new Date().toISOString().replace(/[-:]|\.\d{3}/g, "");
  const day = amz.slice(0, 8);
  const hash = payloadHash ?? sha(body ?? "");
  const all = { ...Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)])), host, "x-amz-date": amz, "x-amz-content-sha256": hash };
  const names = Object.keys(all).sort();
  const canonicalQuery = Object.keys(query).sort().map((k) => `${enc(k)}=${enc(query[k])}`).join("&");
  const canonical = [method, enc(path, true), canonicalQuery, names.map((n) => `${n}:${all[n].trim()}\n`).join(""), names.join(";"), hash].join("\n");
  const scope = `${day}/${config.region}/${service}/aws4_request`;
  let key = hmac(`AWS4${config.secretKey}`, day); key = hmac(key, config.region); key = hmac(key, service); key = hmac(key, "aws4_request");
  const signature = createHmac("sha256", key).update(["AWS4-HMAC-SHA256", amz, scope, sha(canonical)].join("\n")).digest("hex");
  const { host: _, ...sent } = all;
  const response = await fetch(`https://${host}${enc(path, true)}${canonicalQuery ? `?${canonicalQuery}` : ""}`, {
    method, body,
    headers: { ...sent, Authorization: `AWS4-HMAC-SHA256 Credential=${config.accessKey}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}` },
  });
  return { status: response.status, text: await response.text() };
}
const bucketHost = (c) => `${c.bucket}.s3.${c.region}.amazonaws.com`;
async function s3(method, key, options = {}) { const c = awsConfig(); return aws(method, { service: "s3", host: bucketHost(c), path: `/${key}`, ...options }); }

// ---------- cloud scheduling (mirror CloudPublisher.swift) ----------
const scheduleName = (id) => `po-${id.toLowerCase()}`;
const current = (post) => post.cloud && post.cloud.updated === post.updated && post.cloud.date === post.date;
async function push(post) {
  const folder = `scheduled/${post.id}/`;
  const keys = [];
  async function send(path, name) {
    const stat = statSync(path);
    const key = `${folder}media/${name}-${sha(`${path}|${stat.size}|${stat.mtimeMs / 1000}`).slice(0, 12)}${extname(path).toLowerCase()}`;
    if ((await s3("HEAD", key)).status !== 200) {
      const result = await s3("PUT", key, { body: readFileSync(path), payloadHash: "UNSIGNED-PAYLOAD", headers: { "content-type": MIME[extname(path).toLowerCase()] ?? "application/octet-stream" } });
      if (result.status >= 300) throw new Issue(`O S3 recusou o envio de ${basename(path)} (HTTP ${result.status}).`);
    }
    return key;
  }
  for (const [index, path] of post.media.entries()) keys.push(await send(mediaPath(path), String(index)));
  const cover = post.coverPath && existsSync(post.coverPath) ? await send(post.coverPath, "cover") : null;
  const pending = post.platforms.filter((n) => !["ok", "inbox"].includes(post.results?.[n]?.state));
  const revision = randomUUID().toUpperCase();
  const payload = {
    id: post.id, revision, title: post.title, text: post.text, platforms: pending,
    texts: Object.fromEntries(pending.map((n) => [n, textFor(post, n)])), titles: Object.fromEntries(pending.map((n) => [n, titleFor(post, n)])),
    media: keys.map((key) => ({ key })), coverIsFrame: false, stories: post.stories !== false,
    youtubePrivacy: post.youtubePrivacy ?? "private", tags: post.tags ?? [], tiktokPrivacy: post.tiktokPrivacy ?? "INBOX", tiktokAllowComments: post.tiktokAllowComments === true,
    tiktokAllowDuet: post.tiktokAllowDuet === true, tiktokAllowStitch: post.tiktokAllowStitch === true,
    tiktokYourBrand: post.tiktokDisclose === true && post.tiktokYourBrand === true, tiktokBranded: post.tiktokDisclose === true && post.tiktokBranded === true,
    date: fromSwift(post.date).toISOString(),
  };
  if (cover) payload.cover = { key: cover };
  if (post.coverTime != null) payload.coverTimeMs = Math.round(post.coverTime * 1000);
  if (post.facebookPageID) payload.facebookPageID = post.facebookPageID;
  const body = JSON.stringify(payload, null, 2);
  if ((await s3("PUT", `${folder}post.json`, { body, headers: { "content-type": "application/json" } })).status >= 300) throw new Issue("O S3 recusou o post.json.");
  await s3("DELETE", `${folder}result.json`);
  const at = iso(fromSwift(post.date)).slice(0, 19);
  const schedule = JSON.stringify({
    ScheduleExpression: `at(${at})`, ScheduleExpressionTimezone: timeZone(), FlexibleTimeWindow: { Mode: "OFF" }, ActionAfterCompletion: "DELETE", Description: "Trelune (MCP)", ClientToken: revision,
    Target: { Arn: cloudTarget().functionArn, RoleArn: cloudTarget().roleArn, Input: JSON.stringify({ postId: post.id, revision }), RetryPolicy: { MaximumRetryAttempts: 0, MaximumEventAgeInSeconds: 3600 } },
  });
  const options = { service: "scheduler", host: `scheduler.${awsConfig().region}.amazonaws.com`, path: `/schedules/${scheduleName(post.id)}`, body: schedule, headers: { "content-type": "application/json" } };
  let result = await aws("PUT", options);
  if (result.status === 404) result = await aws("POST", options);
  if (result.status >= 300) throw new Issue(`O EventBridge Scheduler recusou o agendamento (HTTP ${result.status}): ${result.text.slice(0, 200)}`);
  return revision;
}
async function deleteRemote(id) {
  const result = await aws("DELETE", { service: "scheduler", host: `scheduler.${awsConfig().region}.amazonaws.com`, path: `/schedules/${scheduleName(id)}`, query: { clientToken: randomUUID() } });
  if (result.status >= 300 && result.status !== 404) throw new Issue(`O Scheduler recusou o cancelamento (HTTP ${result.status}).`);
  await s3("DELETE", `scheduled/${id}/post.json`);
}
const cloudReady = () => workspace().cloudPublishing === true && awsConfig() !== null;
/// Sends a scheduled post to the cloud right away, so it is published even with the Mac off.
async function scheduleInCloud(id) {
  if (!cloudReady()) return "O app do Mac publica este post no horário (publicação pela nuvem desligada).";
  const post = loadPosts().find((p) => p.id === id);
  if (!post || post.status !== STATUS.scheduled || current(post)) return "";
  if (fromSwift(post.date) - Date.now() < 60_000) return "Horário muito próximo para a nuvem; o app do Mac publica se estiver aberto.";
  const revision = await push(post);
  await mutate((posts) => { const item = posts.find((p) => p.id === id); if (item) item.cloud = { revision, updated: post.updated, date: post.date }; });
  return "Agendado na nuvem: publica no horário mesmo com o Mac desligado.";
}
/// Background pass: cancels schedules of deleted posts, collects results and sends posts still missing.
async function syncCloud() {
  if (!awsConfig()) return;
  for (const id of readJSON(FILES.tombstones, [])) {
    try { await deleteRemote(id); writeJSON(FILES.tombstones, readJSON(FILES.tombstones, []).filter((x) => x !== id)); } catch (error) { console.error("cancel", id, error.message); }
  }
  const now = Date.now();
  for (const post of loadPosts()) {
    if (!post.cloud) continue;
    if (fromSwift(post.date) <= now && [STATUS.scheduled, STATUS.publishing].includes(post.status)) {
      const result = await s3("GET", `scheduled/${post.id}/result.json`);
      if (result.status !== 200) continue;
      const data = JSON.parse(result.text);
      await mutate((posts) => {
        const item = posts.find((p) => p.id === post.id);
        if (!item) return;
        for (const [network, value] of Object.entries(data.results ?? {})) item.results[network] = { state: value.state, detail: value.detail, remoteID: value.remoteID, link: value.link, date: toSwift(new Date()) };
        item.status = data.finished ? data.status : STATUS.publishing;
        if (data.finished) delete item.cloud;
        item.updated = toSwift(new Date());
      });
      if (data.finished) for (const name of ["post.json", "result.json"]) await s3("DELETE", `scheduled/${post.id}/${name}`);
    } else if (post.status !== STATUS.scheduled) {
      await deleteRemote(post.id);
      await mutate((posts) => { const item = posts.find((p) => p.id === post.id); if (item) delete item.cloud; });
    }
  }
  // Posts scheduled while the app was closed (and not sent yet) go to the cloud from here.
  if (!cloudReady()) return;
  for (const post of loadPosts()) {
    if (post.status === STATUS.scheduled && !current(post) && fromSwift(post.date) - now > 120_000 && now - fromSwift(post.updated) > 60_000) {
      try { await scheduleInCloud(post.id); } catch (error) { console.error("push", post.id, error.message); }
    }
  }
}

// ---------- MCP tools ----------
function tools() {
  const s = settings();
  const platforms = { type: "array", items: { type: "string", enum: NETWORKS }, description: "Destinos da publicação." };
  const edit = { title: { type: "string" }, text: { type: "string" }, platforms, media_path: { type: "string", description: "Caminho de um arquivo local (ex.: da list_media)." }, media_paths: { type: "array", items: { type: "string" }, description: "Vários arquivos em ordem (carrossel); o primeiro é a capa." }, titles: { type: "object", additionalProperties: { type: "string" }, description: "Título por rede, ex.: {\"YouTube\": \"...\"}." }, overrides: { type: "object", additionalProperties: { type: "string" }, description: "Texto específico por rede." }, public_media_url: { type: "string" }, youtube_privacy: { type: "string", enum: ["private", "unlisted", "public"] }, stories: { type: "boolean", description: "Também publicar a primeira mídia nos Stories do Instagram e do Facebook (padrão: sim)." } };
  const tool = (name, description, properties, required = []) => ({ name, description, inputSchema: { type: "object", properties, required, additionalProperties: false } });
  const list = [
    tool("list_publications", "Lista publicações do workspace, mais recentes primeiro.", { status: { type: "string", enum: Object.values(STATUS) }, platform: { type: "string", enum: NETWORKS }, limit: { type: "integer", minimum: 1, maximum: 200 } }),
    tool("get_publication", "Retorna uma publicação pelo id, com resultados de envio por rede.", { id: { type: "string" } }, ["id"]),
    tool("get_overview", "Resumo do workspace: contagem por status e próximos agendamentos.", {}),
    tool("list_media", "Lista os arquivos da biblioteca de mídia (caminhos locais).", {}),
  ];
  if (s.allowWrite) {
    list.push(tool("create_draft", "Cria um rascunho. Não publica nada.", edit, ["title", "text", "platforms"]));
    list.push(tool("update_publication", "Altera um rascunho ou agendamento existente.", { id: { type: "string" }, ...edit }, ["id"]));
  }
  if (s.allowSchedule) {
    list.push(tool("schedule_publication", "Agenda uma publicação. Com a publicação pela nuvem ligada, sai no horário mesmo com o Mac desligado.", { id: { type: "string" }, date: { type: "string", description: "ISO 8601, ex.: 2026-11-10T09:30:00-03:00. Sem fuso usa o fuso do workspace." } }, ["id", "date"]));
    list.push(tool("unschedule_publication", "Cancela um agendamento e devolve a publicação para rascunhos.", { id: { type: "string" } }, ["id"]));
  }
  if (s.allowDelete) list.push(tool("delete_publication", "Exclui uma publicação local (não apaga conteúdo já publicado nas redes).", { id: { type: "string" } }, ["id"]));
  return list;
}
const denied = () => new Issue("Esta ação não foi permitida para assistentes em MCP e assistentes.");
async function call(name, args) {
  const s = settings();
  if (!s.enabled) throw new Issue("O acesso de assistentes está desativado. Ative em Trelune → MCP e assistentes.");
  switch (name) {
    case "list_publications": {
      const items = loadPosts().filter((p) => (!args.status || p.status === args.status) && (!args.platform || p.platforms.includes(args.platform))).sort((a, b) => b.date - a.date).slice(0, args.limit ?? 50);
      return [items.map(encode), `${items.length} publicação(ões) listada(s)`];
    }
    case "get_publication": { const post = find(loadPosts(), args); return [encode(post), `Consultou “${post.title}”`]; }
    case "get_overview": {
      const posts = loadPosts(), counts = {};
      for (const p of posts) counts[p.status] = (counts[p.status] ?? 0) + 1;
      const upcoming = posts.filter((p) => p.status === STATUS.scheduled).sort((a, b) => a.date - b.date).slice(0, 10).map(encode);
      return [{ total: posts.length, by_status: counts, upcoming, timezone: timeZone(), now: iso(new Date()), cloud_publishing: cloudReady() }, "Resumo do workspace"];
    }
    case "list_media": {
      const files = (workspace().library ?? []).map((path) => ({ path, name: basename(path), kind: kind(path), exists: existsSync(path) }));
      return [files, `${files.length} mídia(s) listada(s)`];
    }
    case "create_draft": {
      if (!s.allowWrite) throw denied();
      const title = String(args.title ?? "").trim();
      if (!title) throw new Issue("Informe o título.");
      const now = toSwift(new Date());
      const post = { id: randomUUID().toUpperCase(), title, text: String(args.text ?? ""), platforms: platformsArg(args.platforms), date: now + 3600, status: STATUS.draft, media: [], overrides: {}, titles: {}, youtubePrivacy: "private", tags: [], tiktokPrivacy: "INBOX", tiktokAllowComments: false, results: {}, created: now, updated: now, stories: true };
      apply(args, post);
      await mutate((posts) => { posts.unshift(post); });
      return [encode(post), `Criou o rascunho “${title}”`];
    }
    case "update_publication": {
      if (!s.allowWrite) throw denied();
      const post = await mutate((posts) => {
        const item = find(posts, args);
        if ([STATUS.publishing, STATUS.published].includes(item.status)) throw new Issue("Publicações enviadas ou em envio não podem ser alteradas.");
        if (typeof args.title === "string") item.title = args.title;
        if (typeof args.text === "string") item.text = args.text;
        if (args.platforms) item.platforms = platformsArg(args.platforms);
        apply(args, item);
        item.updated = toSwift(new Date());
        return item;
      });
      const note = post.status === STATUS.scheduled ? await scheduleInCloud(post.id).catch((e) => `A nuvem não recebeu a alteração: ${e.message}`) : "";
      return [{ ...encode(loadPosts().find((p) => p.id === post.id)), note }, `Alterou “${post.title}”`];
    }
    case "schedule_publication": {
      if (!s.allowSchedule) throw denied();
      const date = parseDate(args.date);
      if (!date) throw new Issue("Data inválida. Use ISO 8601, por exemplo 2026-11-10T09:30:00-03:00.");
      if (date <= new Date()) throw new Issue("A data precisa estar no futuro.");
      const post = await mutate((posts) => {
        const item = find(posts, args);
        if (!item.platforms.length) throw new Issue("A publicação não tem destinos.");
        if ([STATUS.published, STATUS.publishing].includes(item.status)) throw new Issue("Esta publicação já foi enviada.");
        item.date = toSwift(date); item.status = STATUS.scheduled; item.updated = toSwift(new Date());
        return item;
      });
      let note;
      try { note = await scheduleInCloud(post.id); } catch (error) { note = `Agendado no app, mas a nuvem recusou: ${error.message} O app do Mac publica se estiver aberto.`; }
      return [{ ...encode(loadPosts().find((p) => p.id === post.id)), note }, `Agendou “${post.title}” para ${formatLocal(date)}`];
    }
    case "unschedule_publication": {
      if (!s.allowSchedule) throw denied();
      const post = await mutate((posts) => {
        const item = find(posts, args);
        if (item.status !== STATUS.scheduled) throw new Issue("A publicação não está agendada.");
        item.status = STATUS.draft; item.updated = toSwift(new Date());
        return item;
      });
      if (post.cloud && awsConfig()) {
        try { await deleteRemote(post.id); await mutate((posts) => { const item = posts.find((p) => p.id === post.id); if (item) delete item.cloud; }); } catch (error) { console.error(error); }
      }
      return [encode(loadPosts().find((p) => p.id === post.id)), `Cancelou o agendamento de “${post.title}”`];
    }
    case "delete_publication": {
      if (!s.allowDelete) throw denied();
      const post = await mutate((posts) => { const item = find(posts, args); posts.splice(posts.indexOf(item), 1); return item; });
      if (post.cloud) {
        try { await deleteRemote(post.id); } catch { writeJSON(FILES.tombstones, [...new Set([...readJSON(FILES.tombstones, []), post.id])]); }
      }
      return [{ deleted: post.id }, `Excluiu “${post.title}”`];
    }
    default: throw new Issue(`Ferramenta desconhecida: ${name}`);
  }
}

// ---------- JSON-RPC over stdio ----------
const VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
async function handle(message) {
  if (message.id === undefined) return; // notification
  const reply = (result) => send({ jsonrpc: "2.0", id: message.id, result });
  const params = message.params ?? {};
  switch (message.method) {
    case "initialize":
      return reply({ protocolVersion: VERSIONS.includes(params.protocolVersion) ? params.protocolVersion : VERSIONS[0], capabilities: { tools: { listChanged: false } }, serverInfo: { name: "trelune", version: "2.0.0" },
        instructions: `Gerencia rascunhos e agendamentos do Trelune. Datas em ISO 8601; sem fuso, usa o fuso do workspace (${timeZone()}). ${cloudReady() ? "Agendamentos vão para a nuvem e são publicados no horário mesmo com o Mac desligado." : "O app do Mac publica os agendamentos no horário enquanto estiver aberto."}` });
    case "ping": return reply({});
    case "tools/list": return reply({ tools: tools() });
    case "tools/call": {
      const name = params.name ?? "";
      try {
        const [payload, summary] = await call(name, params.arguments ?? {});
        log(name, true, summary);
        return reply({ content: [{ type: "text", text: JSON.stringify(payload, null, 2) }], isError: false });
      } catch (error) {
        const text = error instanceof Issue ? error.message : `Erro inesperado: ${error.message}`;
        log(name, false, text);
        return reply({ content: [{ type: "text", text }], isError: true });
      }
    }
    default: return send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Método não suportado: ${message.method}` } });
  }
}

if (process.argv.includes("--stdio")) {
  let queue = Promise.resolve();
  createInterface({ input: process.stdin }).on("line", (line) => {
    if (!line.trim()) return;
    let message;
    try { message = JSON.parse(line); } catch { return send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }); }
    queue = queue.then(() => handle(message)).catch((error) => console.error(error));
  });
} else if (process.argv.includes("--check-network")) {
  // Confirms the egress rules: allowed provider hosts answer, anything else is blocked.
  for (const url of ["https://graph.facebook.com/", "https://open.tiktokapis.com/", "https://www.googleapis.com/", "https://example.com/", "https://registry.npmjs.org/"]) {
    try { const r = await fetch(url, { signal: AbortSignal.timeout(8000) }); console.log(`${url} -> HTTP ${r.status}`); } catch (error) { console.log(`${url} -> bloqueado (${error.cause?.code ?? error.message})`); }
  }
} else {
  console.log("trelune MCP pronto. Clientes conectam com: docker exec -i trelune-mcp node /app/server.mjs --stdio");
  const loop = async () => { try { await syncCloud(); } catch (error) { console.error("sync", error.message); } setTimeout(loop, 60_000); };
  loop();
}
