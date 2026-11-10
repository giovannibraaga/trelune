// Trelune cloud publisher (deployed by cloud/deploy.sh).
// Triggered by a one-time EventBridge Scheduler schedule with {"postId": "<uuid>"}.
// Reads scheduled/<postId>/post.json from S3, publishes to each network with the
// credentials stored in SSM Parameter Store and writes scheduled/<postId>/result.json.
import { S3Client, GetObjectCommand, PutObjectCommand, CopyObjectCommand, DeleteObjectCommand, ListObjectsV2Command } from "@aws-sdk/client-s3";
import { SSMClient, GetParameterCommand, PutParameterCommand } from "@aws-sdk/client-ssm";

const BUCKET = process.env.BUCKET;
if (!BUCKET) throw new Error("Defina a variável BUCKET da Lambda (cloud/deploy.sh faz isso).");
const REGION = process.env.AWS_REGION ?? "us-east-1";
const PUBLIC_PREFIX = process.env.PUBLIC_PREFIX ?? "trelune/";
const VAULT = process.env.VAULT_PATH ?? "/trelune/vault/";
const s3 = new S3Client({ region: REGION });
const ssm = new SSMClient({ region: REGION });

// Swift's JSONEncoder stores Date as seconds since 2001-01-01.
const SWIFT_EPOCH = 978307200;
const fromSwift = (value) => new Date(((value ?? -63114076800) + SWIFT_EPOCH) * 1000);
const toSwift = (date) => date.getTime() / 1000 - SWIFT_EPOCH;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const isVideo = (key) => /\.(mp4|mov|m4v|webm)$/i.test(key);
const mime = (key) => ({ jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp", mp4: "video/mp4", m4v: "video/mp4", mov: "video/quicktime", webm: "video/webm" })[key.split(".").pop().toLowerCase()] ?? "application/octet-stream";
class Failure extends Error {}

// ---------- storage ----------
async function readJSON(key) {
  try {
    const object = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
    return JSON.parse(await object.Body.transformToString());
  } catch (error) {
    if (error.name === "NoSuchKey") return null;
    throw error;
  }
}
const writeJSON = (key, value) => s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: key, Body: JSON.stringify(value, null, 2), ContentType: "application/json" }));
const bytes = new Map();
async function download(key) {
  if (!bytes.has(key)) {
    const object = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
    bytes.set(key, Buffer.from(await object.Body.transformToByteArray()));
  }
  return bytes.get(key);
}
const publicURLs = new Map();
// Networks that fetch media by URL get a copy in the public prefix (expires in 7 days).
async function publicURL(key) {
  if (!publicURLs.has(key)) {
    const target = `${PUBLIC_PREFIX}cloud/${key.replace(/^scheduled\//, "").replaceAll("/", "-")}`;
    await s3.send(new CopyObjectCommand({ Bucket: BUCKET, Key: target, CopySource: `${BUCKET}/${encodeURIComponent(key).replaceAll("%2F", "/")}`, ContentType: mime(key), MetadataDirective: "REPLACE" }));
    publicURLs.set(key, `https://${BUCKET}.s3.${REGION}.amazonaws.com/${target.split("/").map(encodeURIComponent).join("/")}`);
  }
  return publicURLs.get(key);
}

// ---------- credentials ----------
async function vault(name) {
  try {
    const result = await ssm.send(new GetParameterCommand({ Name: VAULT + name, WithDecryption: true }));
    return JSON.parse(result.Parameter.Value);
  } catch (error) {
    if (error.name === "ParameterNotFound") throw new Failure("Conta não sincronizada com a nuvem. Abra o app no Mac para enviar a conexão.");
    throw error;
  }
}
const saveVault = (name, value) => ssm.send(new PutParameterCommand({ Name: VAULT + name, Value: JSON.stringify(value), Type: "SecureString", Overwrite: true, Tier: "Intelligent-Tiering" }));

// ---------- http ----------
async function http(url, options = {}, label = "A rede") {
  const response = await fetch(url, options);
  const text = await response.text();
  let body; try { body = text ? JSON.parse(text) : {}; } catch { body = { raw: text }; }
  if (!response.ok) {
    const detail = body?.error?.message ?? body?.error?.code ?? body?.detail ?? body?.title ?? body?.error_description ?? `HTTP ${response.status}`;
    throw new Failure(`${label} recusou a operação: ${detail}.`);
  }
  return { body, response };
}
const form = (values) => new URLSearchParams(Object.entries(values).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => [k, String(v)]));

// ---------- YouTube ----------
async function youtube(post) {
  const config = await vault("youtube");
  if (fromSwift(config.expires) < new Date(Date.now() + 30_000)) {
    if (!config.refreshToken) throw new Failure("A autorização do YouTube expirou. Autorize novamente no app.");
    const { body } = await http("https://oauth2.googleapis.com/token", { method: "POST", body: form({ client_id: config.clientID, client_secret: config.clientSecret, grant_type: "refresh_token", refresh_token: config.refreshToken }) }, "O Google");
    config.accessToken = body.access_token; config.expires = toSwift(new Date(Date.now() + body.expires_in * 1000));
    await saveVault("youtube", config);
  }
  const video = post.media.find((m) => isVideo(m.key));
  const data = await download(video.key);
  const title = post.titles.YouTube ?? post.title;
  const snippet = { title, description: post.texts.YouTube ?? post.text };
  if (post.tags?.length) snippet.tags = post.tags;
  const type = mime(video.key);
  const start = await fetch("https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status", {
    method: "POST",
    headers: { Authorization: `Bearer ${config.accessToken}`, "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Length": String(data.length), "X-Upload-Content-Type": type },
    body: JSON.stringify({ snippet, status: { privacyStatus: post.youtubePrivacy, selfDeclaredMadeForKids: false } }),
  });
  const location = start.headers.get("location");
  if (!start.ok || !location?.startsWith("https://www.googleapis.com/")) throw new Failure("O YouTube não iniciou o envio. Confirme a permissão de upload e a cota diária do canal.");
  const { body: uploaded } = await http(location, { method: "PUT", headers: { Authorization: `Bearer ${config.accessToken}`, "Content-Type": type }, body: data }, "O YouTube");
  const id = uploaded.id ?? "";
  let note = "";
  if (post.cover && id) {
    const image = await download(post.cover.key);
    if (image.length > 2_000_000) note = " Miniatura não enviada: imagem acima de 2 MB.";
    else {
      const thumb = await fetch(`https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=${id}&uploadType=media`, { method: "POST", headers: { Authorization: `Bearer ${config.accessToken}`, "Content-Type": mime(post.cover.key) }, body: image });
      note = thumb.ok ? " Miniatura personalizada aplicada." : " O YouTube recusou a miniatura (o canal precisa estar verificado).";
    }
  }
  const privacy = { public: "público", unlisted: "não listado" }[post.youtubePrivacy] ?? "privado";
  return { state: "ok", detail: `Vídeo enviado (${privacy}).${note}`, remoteID: id, link: id ? `https://youtu.be/${id}` : undefined };
}

// ---------- Meta ----------
const GRAPH = "https://graph.facebook.com/v26.0";
async function graph(path, token, fields) {
  const { body } = await http(`${GRAPH}/${path}?${form(fields)}`, { method: "POST", headers: { Authorization: `Bearer ${token}` } }, "A Meta");
  return body;
}
async function graphGet(path, token, query) {
  const { body } = await http(`${GRAPH}/${path}?${form(query)}`, { headers: { Authorization: `Bearer ${token}` } }, "A Meta");
  return body;
}
async function metaPages() {
  const config = await vault("meta");
  if (!config.pages?.length) throw new Failure("Nenhuma Página autorizada na conexão Meta.");
  return config.pages;
}
async function waitContainer(id, token, attempts) {
  for (let i = 0; i < attempts; i++) {
    const state = await graphGet(id, token, { fields: "status_code,status" });
    if (state.status_code === "FINISHED") return;
    if (state.status_code === "ERROR" || state.status_code === "EXPIRED") throw new Failure(state.status ?? "A Meta não processou esta mídia do Instagram.");
    await sleep(5000);
  }
  throw new Failure("A Meta ainda está processando a mídia.");
}
async function facebook(post) {
  const pages = await metaPages();
  const page = pages.find((p) => p.id === post.facebookPageID) ?? pages[0];
  const text = post.texts.Facebook ?? post.text;
  const videos = post.media.filter((m) => isVideo(m.key)), images = post.media.filter((m) => !isVideo(m.key));
  let id;
  if (videos.length === 1) {
    const data = await download(videos[0].key);
    const start = await graph(`${page.id}/video_reels`, page.accessToken, { upload_phase: "start" });
    const target = start.upload_url ?? `https://rupload.facebook.com/video-upload/v26.0/${start.video_id}`;
    if (!target.startsWith("https://rupload.facebook.com/")) throw new Failure("A Meta retornou um destino de vídeo inválido.");
    await http(target, { method: "POST", headers: { Authorization: `OAuth ${page.accessToken}`, offset: "0", file_size: String(data.length), "Content-Type": "application/octet-stream" }, body: data }, "A Meta");
    const finished = await graph(`${page.id}/video_reels`, page.accessToken, { video_id: start.video_id, upload_phase: "finish", video_state: "PUBLISHED", description: text });
    if (!finished.success) throw new Failure("A Meta recebeu o vídeo, mas não confirmou a publicação do Reel.");
    id = start.video_id;
  } else if (images.length > 1) {
    const ids = [];
    for (const image of images) ids.push((await graph(`${page.id}/photos`, page.accessToken, { url: await publicURL(image.key), published: false })).id);
    const fields = { message: text };
    ids.forEach((media, index) => { fields[`attached_media[${index}]`] = JSON.stringify({ media_fbid: media }); });
    id = (await graph(`${page.id}/feed`, page.accessToken, fields)).id;
  } else if (images.length === 1) {
    const result = await graph(`${page.id}/photos`, page.accessToken, { url: await publicURL(images[0].key), message: text });
    id = result.post_id ?? result.id;
  } else {
    id = (await graph(`${page.id}/feed`, page.accessToken, { message: text })).id;
  }
  let detail = `Publicado na Página ${page.name}.`;
  if (post.stories !== false && post.media.length) {
    try { await facebookStory(page, post.media[0].key); detail += " Story publicado."; }
    catch (error) { detail += ` Story não publicado: ${error.message}`; }
  }
  return { state: "ok", detail, remoteID: id, link: `https://www.facebook.com/${id}` };
}
async function facebookStory(page, key) {
  let result;
  if (isVideo(key)) {
    const data = await download(key);
    const start = await graph(`${page.id}/video_stories`, page.accessToken, { upload_phase: "start" });
    const target = start.upload_url ?? `https://rupload.facebook.com/video-upload/v26.0/${start.video_id}`;
    if (!target.startsWith("https://rupload.facebook.com/")) throw new Failure("A Meta retornou um destino de vídeo inválido.");
    await http(target, { method: "POST", headers: { Authorization: `OAuth ${page.accessToken}`, offset: "0", file_size: String(data.length), "Content-Type": "application/octet-stream" }, body: data }, "A Meta");
    result = await graph(`${page.id}/video_stories`, page.accessToken, { video_id: start.video_id, upload_phase: "finish" });
  } else {
    const photo = await graph(`${page.id}/photos`, page.accessToken, { url: await publicURL(key), published: false });
    result = await graph(`${page.id}/photo_stories`, page.accessToken, { photo_id: photo.id });
  }
  if (result.success === false) throw new Failure("A Meta não confirmou o Story.");
}
async function instagram(post) {
  const pages = await metaPages();
  const page = pages.find((p) => p.id === post.facebookPageID && p.instagramID) ?? pages.find((p) => p.instagramID);
  if (!page) throw new Failure("Nenhuma Página com Instagram profissional vinculado.");
  const ig = page.instagramID, token = page.accessToken;
  const caption = post.texts.Instagram ?? post.text;
  const urls = [];
  for (const item of post.media) urls.push(await publicURL(item.key));
  let creation;
  if (urls.length > 1) {
    const children = [];
    for (const url of urls) {
      const fields = isVideo(url) ? { is_carousel_item: true, media_type: "VIDEO", video_url: url } : { is_carousel_item: true, image_url: url };
      const child = await graph(`${ig}/media`, token, fields);
      await waitContainer(child.id, token, isVideo(url) ? 120 : 24);
      children.push(child.id);
    }
    creation = (await graph(`${ig}/media`, token, { media_type: "CAROUSEL", children: children.join(","), caption })).id;
    await waitContainer(creation, token, 60);
  } else {
    const reel = isVideo(urls[0]);
    const fields = reel ? { media_type: "REELS", video_url: urls[0], caption } : { image_url: urls[0], caption };
    if (reel && post.cover && !post.coverIsFrame) fields.cover_url = await publicURL(post.cover.key);
    else if (reel && post.coverTimeMs != null) fields.thumb_offset = post.coverTimeMs;
    creation = (await graph(`${ig}/media`, token, fields)).id;
    await waitContainer(creation, token, reel ? 120 : 24);
  }
  const published = await graph(`${ig}/media_publish`, token, { creation_id: creation });
  let detail = `Publicado em @${page.instagramUsername ?? ""} · ${urls.length > 1 ? "Carrossel" : isVideo(urls[0]) ? "Reels" : "Imagem"}.`;
  if (post.stories !== false) {
    try {
      const story = (await graph(`${ig}/media`, token, isVideo(urls[0]) ? { media_type: "STORIES", video_url: urls[0] } : { media_type: "STORIES", image_url: urls[0] })).id;
      await waitContainer(story, token, isVideo(urls[0]) ? 120 : 24);
      await graph(`${ig}/media_publish`, token, { creation_id: story });
      detail += " Story publicado.";
    } catch (error) { detail += ` Story não publicado: ${error.message}`; }
  }
  return { state: "ok", detail, remoteID: published.id };
}

// ---------- Threads ----------
async function threads(post) {
  const config = await vault("threads");
  const expires = fromSwift(config.expires), refreshed = fromSwift(config.refreshed);
  if (expires < new Date()) throw new Failure("O token do Threads expirou. Gere um novo e conecte de novo no app.");
  if (expires < new Date(Date.now() + 10 * 86400_000) && refreshed < new Date(Date.now() - 86400_000)) {
    const { body } = await http(`https://graph.threads.net/refresh_access_token?${form({ grant_type: "th_refresh_token", access_token: config.token })}`, {}, "O Threads");
    config.token = body.access_token; config.expires = toSwift(new Date(Date.now() + (body.expires_in ?? 5_184_000) * 1000)); config.refreshed = toSwift(new Date());
    await saveVault("threads", config);
  }
  const api = "https://graph.threads.net/v1.0";
  const call = async (path, fields) => (await http(`${api}/${path}?${form({ ...fields, access_token: config.token })}`, { method: "POST" }, "O Threads")).body;
  const wait = async (id, text) => {
    for (let i = 0; i < 60; i++) {
      const { body } = await http(`${api}/${id}?${form({ fields: "status,error_message", access_token: config.token })}`, {}, "O Threads");
      if (body.status === "FINISHED" || (!body.status && text)) return;
      if (body.status === "ERROR" || body.status === "EXPIRED") throw new Failure(`O Threads não processou a mídia: ${body.error_message ?? "erro não informado"}.`);
      await sleep(text ? 1000 : 5000);
    }
    throw new Failure("O Threads ainda está processando a mídia.");
  };
  const text = post.texts.Threads ?? post.text;
  const urls = [];
  for (const item of post.media) urls.push(await publicURL(item.key));
  const fieldsFor = (url) => isVideo(url) ? { media_type: "VIDEO", video_url: url } : { media_type: "IMAGE", image_url: url };
  let container;
  if (urls.length > 1) {
    const children = [];
    for (const url of urls) {
      const child = await call(`${config.userID}/threads`, { ...fieldsFor(url), is_carousel_item: true });
      await wait(child.id, false);
      children.push(child.id);
    }
    container = (await call(`${config.userID}/threads`, { media_type: "CAROUSEL", children: children.join(","), text })).id;
  } else {
    container = (await call(`${config.userID}/threads`, { ...(urls[0] ? fieldsFor(urls[0]) : { media_type: "TEXT" }), text })).id;
  }
  await wait(container, urls.length === 0);
  const published = await call(`${config.userID}/threads_publish`, { creation_id: container });
  return { state: "ok", detail: `Publicado em @${config.username}.`, remoteID: published.id };
}

// ---------- TikTok ----------
async function tiktokToken() {
  const config = await vault("tiktok");
  if (fromSwift(config.expires) > new Date(Date.now() + 60_000)) return config.token;
  if (fromSwift(config.refreshExpires) < new Date()) throw new Failure("A autorização do TikTok expirou. Conecte a conta novamente no app.");
  const { body } = await http("https://open.tiktokapis.com/v2/oauth/token/", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: form({ client_key: config.key, client_secret: config.secret, grant_type: "refresh_token", refresh_token: config.refresh }) }, "O TikTok");
  if (!body.access_token) throw new Failure("O TikTok não renovou a autorização. Conecte a conta novamente no app.");
  Object.assign(config, { token: body.access_token, refresh: body.refresh_token ?? config.refresh, expires: toSwift(new Date(Date.now() + body.expires_in * 1000)), refreshExpires: toSwift(new Date(Date.now() + body.refresh_expires_in * 1000)), openID: body.open_id ?? config.openID, scope: body.scope ?? config.scope });
  await saveVault("tiktok", config);
  return config.token;
}
async function tiktokAPI(path, body, token) {
  const response = await fetch(`https://open.tiktokapis.com/v2/${path}`, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json; charset=UTF-8" }, body: JSON.stringify(body) });
  const result = await response.json().catch(() => ({}));
  if (result?.error?.code === "unaudited_client_can_only_post_to_private_accounts") throw new Failure("O TikTok só aceita envio direto de apps não auditados quando a conta inteira é privada. Use o envio para a caixa de entrada ou solicite a auditoria do app (Direct Post).");
  if (!response.ok || result?.error?.code !== "ok") throw new Failure(`O TikTok recusou a operação: ${result?.error?.code ?? `HTTP ${response.status}`}${result?.error?.message ? ` (${result.error.message})` : ""}.`);
  return result.data;
}
async function tiktok(post) {
  const token = await tiktokToken();
  const draft = post.tiktokPrivacy === "INBOX";
  const videos = post.media.filter((m) => isVideo(m.key));
  let started;
  if (!draft) {
    const info = await tiktokAPI("post/publish/creator_info/query/", {}, token);
    if (!info.privacy_level_options?.includes(post.tiktokPrivacy)) throw new Failure(`A privacidade escolhida não está disponível (${(info.privacy_level_options ?? []).join(", ")}).`);
  }
  if (videos.length === 1) {
    const data = await download(videos[0].key);
    const size = data.length, base = 10_000_000, count = Math.max(1, Math.floor(size / base));
    const chunks = Array.from({ length: count }, (_, i) => ({ offset: i * base, size: i === count - 1 ? size - i * base : base }));
    const body = { source_info: { source: "FILE_UPLOAD", video_size: size, chunk_size: chunks[0].size, total_chunk_count: count } };
    if (!draft) {
      body.post_info = { title: post.texts.TikTok ?? post.text, privacy_level: post.tiktokPrivacy, disable_comment: !post.tiktokAllowComments, disable_duet: !post.tiktokAllowDuet, disable_stitch: !post.tiktokAllowStitch, brand_content_toggle: post.tiktokBranded === true, brand_organic_toggle: post.tiktokYourBrand === true, is_aigc: false };
      if (post.coverTimeMs != null) body.post_info.video_cover_timestamp_ms = post.coverTimeMs;
    }
    started = await tiktokAPI(draft ? "post/publish/inbox/video/init/" : "post/publish/video/init/", body, token);
    if (!/^https:\/\/([a-z0-9-]+\.)*tiktokapis\.com\//.test(started.upload_url)) throw new Failure("A API do TikTok retornou um destino de upload inválido.");
    for (const chunk of chunks) {
      const response = await fetch(started.upload_url, { method: "PUT", headers: { "Content-Type": mime(videos[0].key), "Content-Length": String(chunk.size), "Content-Range": `bytes ${chunk.offset}-${chunk.offset + chunk.size - 1}/${size}` }, body: data.subarray(chunk.offset, chunk.offset + chunk.size) });
      if (response.status !== (chunk.offset + chunk.size === size ? 201 : 206)) throw new Failure("O TikTok interrompeu o upload do vídeo.");
    }
  } else {
    const urls = [];
    for (const item of post.media) urls.push(await publicURL(item.key));
    const postInfo = { title: (post.titles.TikTok ?? post.title).slice(0, 90), description: (post.texts.TikTok ?? post.text).slice(0, 4000), disable_comment: !post.tiktokAllowComments, auto_add_music: true };
    if (!draft) postInfo.privacy_level = post.tiktokPrivacy;
    started = await tiktokAPI("post/publish/content/init/", { post_info: postInfo, source_info: { source: "PULL_FROM_URL", photo_cover_index: 0, photo_images: urls }, post_mode: draft ? "MEDIA_UPLOAD" : "DIRECT_POST", media_type: "PHOTO" }, token);
  }
  for (let i = 0; i < 40; i++) {
    const status = await tiktokAPI("post/publish/status/fetch/", { publish_id: started.publish_id }, token);
    if (status.status === "FAILED") throw new Failure(`O TikTok recusou o envio: ${status.fail_reason ?? "motivo não informado"}.`);
    if (status.status === "PUBLISH_COMPLETE") return { state: "ok", detail: "Publicado no TikTok.", remoteID: started.publish_id };
    if (status.status === "SEND_TO_USER_INBOX") return { state: "inbox", detail: "Entregue na caixa de entrada do TikTok. Finalize a publicação no app do TikTok.", remoteID: started.publish_id };
    await sleep(4000);
  }
  return { state: "inbox", detail: "Enviado ao TikTok; o processamento continua no TikTok.", remoteID: started.publish_id };
}

// ---------- X ----------
async function x(post) {
  const config = await vault("x");
  if (fromSwift(config.expires) < new Date(Date.now() + 60_000)) {
    if (!config.refreshToken) throw new Failure("A autorização do X expirou. Autorize novamente no app.");
    const headers = { "Content-Type": "application/x-www-form-urlencoded" };
    if (config.clientSecret) headers.Authorization = `Basic ${Buffer.from(`${config.clientID}:${config.clientSecret}`).toString("base64")}`;
    const { body } = await http("https://api.x.com/2/oauth2/token", { method: "POST", headers, body: form({ grant_type: "refresh_token", refresh_token: config.refreshToken, client_id: config.clientID }) }, "O X");
    config.accessToken = body.access_token; if (body.refresh_token) config.refreshToken = body.refresh_token;
    config.expires = toSwift(new Date(Date.now() + (body.expires_in ?? 7200) * 1000));
    await saveVault("x", config); // X rotates refresh tokens: save before anything else can fail.
  }
  const auth = { Authorization: `Bearer ${config.accessToken}` };
  const ids = [];
  for (const image of post.media.filter((m) => !isVideo(m.key))) {
    const data = await download(image.key);
    const upload = new FormData();
    upload.append("media_category", image.key.toLowerCase().endsWith(".gif") ? "tweet_gif" : "tweet_image");
    upload.append("media", new Blob([data], { type: mime(image.key) }), image.key.split("/").pop());
    const { body } = await http("https://api.x.com/2/media/upload", { method: "POST", headers: auth, body: upload }, "O X");
    ids.push(body.data?.id ?? body.media_id_string);
  }
  const payload = { text: post.texts.X ?? post.text };
  if (ids.length) payload.media = { media_ids: ids };
  const { body } = await http("https://api.x.com/2/tweets", { method: "POST", headers: { ...auth, "Content-Type": "application/json" }, body: JSON.stringify(payload) }, "O X");
  return { state: "ok", detail: `Publicado em @${config.username}.`, remoteID: body.data.id, link: `https://x.com/${config.username}/status/${body.data.id}` };
}

const publishers = { YouTube: youtube, Facebook: facebook, Instagram: instagram, Threads: threads, TikTok: tiktok, X: x };

// ---------- check (no publishing) ----------
// {"check": true} confirms every synced connection works from the cloud without posting anything.
async function check() {
  const report = {};
  const probe = async (name, run) => { try { report[name] = `ok: ${await run()}`; } catch (error) { report[name] = error instanceof Failure ? error.message : `erro: ${error.message}`; } };
  await probe("youtube", async () => {
    const config = await vault("youtube");
    const { body } = await http("https://oauth2.googleapis.com/token", { method: "POST", body: form({ client_id: config.clientID, client_secret: config.clientSecret, grant_type: "refresh_token", refresh_token: config.refreshToken }) }, "O Google");
    const { body: channel } = await http("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", { headers: { Authorization: `Bearer ${body.access_token}` } }, "O YouTube");
    return channel.items?.[0]?.snippet?.title ?? "sem canal";
  });
  await probe("meta", async () => {
    const pages = await metaPages();
    const names = [];
    for (const page of pages) names.push((await graphGet(page.id, page.accessToken, { fields: "name" })).name + (page.instagramID ? ` + @${(await graphGet(page.instagramID, page.accessToken, { fields: "username" })).username}` : ""));
    return names.join(", ");
  });
  await probe("threads", async () => {
    const config = await vault("threads");
    return "@" + (await http(`https://graph.threads.net/v1.0/me?${form({ fields: "username", access_token: config.token })}`, {}, "O Threads")).body.username;
  });
  await probe("tiktok", async () => {
    const token = await tiktokToken();
    const response = await fetch("https://open.tiktokapis.com/v2/user/info/?fields=display_name", { headers: { Authorization: `Bearer ${token}` } });
    const body = await response.json();
    if (body?.error?.code !== "ok") throw new Failure(`O TikTok recusou: ${body?.error?.code}`);
    return body.data.user.display_name;
  });
  await probe("x", async () => {
    const config = await vault("x");
    if (fromSwift(config.expires) < new Date()) return `token expirado; será renovado na publicação (@${config.username})`;
    return "@" + (await http("https://api.x.com/2/users/me", { headers: { Authorization: `Bearer ${config.accessToken}` } }, "O X")).body.data.username;
  });
  return report;
}

// ---------- handler ----------
export async function handler(event) {
  if (event?.check) return check();
  if (event?.tiktokStatus) return tiktokAPI("post/publish/status/fetch/", { publish_id: event.tiktokStatus }, await tiktokToken());
  const postId = event?.postId;
  if (!/^[0-9A-Fa-f-]{36}$/.test(postId ?? "")) throw new Error("postId inválido");
  const base = `scheduled/${postId}/`;
  const post = await readJSON(`${base}post.json`);
  if (!post) return { skipped: "post.json ausente (publicação removida)" };
  // The app and the MCP container may both (re)send a post; the scheduled time in post.json is what counts.
  if (post.date && Math.abs(Date.parse(post.date) - Date.now()) > 15 * 60_000) return { skipped: `fora do horário do post (${post.date})` };
  const previous = (await readJSON(`${base}result.json`)) ?? { results: {} };
  if (previous.status === "Publicando" && Date.now() - Date.parse(previous.started) < 20 * 60_000) return { skipped: "já está publicando" };
  const result = { status: "Publicando", started: new Date().toISOString(), revision: post.revision, results: { ...(post.results ?? {}), ...previous.results } };
  await writeJSON(`${base}result.json`, result);
  for (const network of post.platforms) {
    if (["ok", "inbox"].includes(result.results[network]?.state)) continue;
    try {
      const publish = publishers[network];
      if (!publish) throw new Failure("Rede sem integração na nuvem.");
      result.results[network] = await publish(post);
    } catch (error) {
      console.error(network, error);
      result.results[network] = { state: "failed", detail: error instanceof Failure ? error.message : `Erro inesperado: ${error.message}` };
    }
    await writeJSON(`${base}result.json`, result);
  }
  const done = post.platforms.filter((n) => ["ok", "inbox"].includes(result.results[n]?.state));
  const pending = post.platforms.some((n) => result.results[n]?.state === "inbox");
  result.status = done.length === post.platforms.length ? (pending ? "Parcial" : "Publicado") : done.length === 0 ? "Falhou" : "Parcial";
  result.finished = new Date().toISOString();
  await writeJSON(`${base}result.json`, result);
  // Media is no longer needed once every destination went out; post.json and result.json stay for the app.
  if (done.length === post.platforms.length) {
    const listed = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: `${base}media/` }));
    for (const object of listed.Contents ?? []) await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: object.Key }));
  }
  return { status: result.status, results: Object.fromEntries(Object.entries(result.results).map(([k, v]) => [k, v.state])) };
}
