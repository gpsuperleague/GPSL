import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { SAMPLE_PNG, SAMPLE_WAV } from "./samples.ts";

const DISCORD_API = "https://discord.com/api/v10";
const GUILD_ID_FALLBACK = "1483974134361886802";

function adminClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL") || "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
  );
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function authorised(req: Request): boolean {
  const feedKey = Deno.env.get("DISCORD_FEED_INVOKE_KEY") || Deno.env.get("CRON_API_KEY") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  return !!bearer && (bearer === feedKey || bearer === serviceKey);
}

function channelSlug(name: string): string {
  const folded = Array.from(name.normalize("NFKC"), (ch) => {
    const c = ch.codePointAt(0) || 0;
    if (c >= 0x1d400 && c <= 0x1d419) return String.fromCharCode(c - 0x1d400 + 65);
    if (c >= 0x1d41a && c <= 0x1d433) return String.fromCharCode(c - 0x1d41a + 97);
    return ch;
  }).join("");
  return folded.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function money(n: number): string {
  return `₿${Math.round(Number(n) || 0).toLocaleString("en-GB")}`;
}

function prizeFor(place: number, quiz: Record<string, unknown>): number {
  const raw = place === 1
    ? quiz.prize_1
    : place === 2
      ? quiz.prize_2
      : place === 3
        ? quiz.prize_3
        : quiz.prize_rest;
  const n = Number(raw);
  return Number.isFinite(n) ? n : 0;
}

type Row = {
  owner_tag?: string;
  points?: number;
  place?: number;
  answers?: number;
};

function boardText(title: string, reveal: string, rows: Row[], withPrizes: Record<string, unknown> | null): string {
  const lines = (rows || []).slice(0, 25).map((r) => {
    const tag = r.owner_tag || "Owner";
    const prize = withPrizes ? ` — ${money(prizeFor(Number(r.place) || 0, withPrizes))}` : "";
    return `${r.place}. ${tag} — ${r.points ?? 0}${prize}`;
  });
  const extra = (rows || []).length > 25 ? `\n… and ${rows.length - 25} more` : "";
  const empty = lines.length ? lines.join("\n") : "No answers yet.";
  return `${title}\nAnswer: ${reveal}\n\n${empty}${extra}`.slice(0, 1900);
}

async function discord(
  token: string,
  path: string,
  init?: RequestInit
): Promise<Response> {
  return fetch(`${DISCORD_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bot ${token}`,
      ...(init?.body instanceof FormData ? {} : { "Content-Type": "application/json" }),
      ...(init?.headers || {}),
    },
  });
}

async function findPubQuizChannel(token: string): Promise<string> {
  const guild = Deno.env.get("DISCORD_GUILD_ID") || GUILD_ID_FALLBACK;
  const res = await discord(token, `/guilds/${guild}/channels`);
  if (!res.ok) throw new Error(`Channel list ${res.status}`);
  const rows = (await res.json()) as { id: string; name: string; type: number }[];
  const hit = rows.find((c) => c.type === 0 && channelSlug(c.name || "") === "pubquiz");
  if (!hit) throw new Error("No #pub quiz channel");
  return hit.id;
}

async function postMessage(
  token: string,
  channelId: string,
  payload: Record<string, unknown>,
  file?: { name: string; bytes: Uint8Array }
): Promise<string> {
  let res: Response;
  if (file) {
    const form = new FormData();
    form.append("payload_json", JSON.stringify({ allowed_mentions: { parse: [] }, ...payload }));
    form.append("files[0]", new Blob([file.bytes]), file.name);
    res = await discord(token, `/channels/${channelId}/messages`, { method: "POST", body: form });
  } else {
    res = await discord(token, `/channels/${channelId}/messages`, {
      method: "POST",
      body: JSON.stringify({ allowed_mentions: { parse: [] }, ...payload }),
    });
  }
  if (!res.ok) throw new Error(`Post ${res.status}: ${(await res.text()).slice(0, 180)}`);
  const msg = (await res.json()) as { id: string };
  return msg.id;
}

async function editMessage(token: string, channelId: string, messageId: string, content: string) {
  const res = await discord(token, `/channels/${channelId}/messages/${messageId}`, {
    method: "PATCH",
    body: JSON.stringify({ content, allowed_mentions: { parse: [] } }),
  });
  if (!res.ok) console.warn("edit", res.status);
}

async function deleteMessage(token: string, channelId: string, messageId: string | null) {
  if (!channelId || !messageId) return;
  const res = await discord(token, `/channels/${channelId}/messages/${messageId}`, { method: "DELETE" });
  if (!res.ok && res.status !== 404) console.warn("delete", res.status);
}

async function pinMessage(token: string, channelId: string, messageId: string) {
  const res = await discord(token, `/channels/${channelId}/pins/${messageId}`, { method: "PUT" });
  if (!res.ok) console.warn("pin", res.status);
}

async function downloadMedia(path: string): Promise<Uint8Array> {
  const base = Deno.env.get("SUPABASE_URL") || "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const res = await fetch(`${base}/storage/v1/object/pub-quiz/${path}`, {
    headers: { Authorization: `Bearer ${key}`, apikey: key },
  });
  if (!res.ok) throw new Error(`Media ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

function publicMediaUrl(path: string): string {
  const base = Deno.env.get("SUPABASE_URL") || "";
  return `${base}/storage/v1/object/public/pub-quiz/${encodeURI(path)}`;
}

async function selfInvoke() {
  const base = Deno.env.get("SUPABASE_URL") || "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  await fetch(`${base}/functions/v1/discord-pub-quiz`, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ action: "kick" }),
  });
}

async function release(db: SupabaseClient, id: number) {
  await db.rpc("gpsl_pub_quiz_runner_release", { p_id: id });
}

function questionPayload(q: Record<string, unknown>) {
  const closes = Math.floor(new Date(String(q.closes_at)).getTime() / 1000);
  const rounds = Number(q.round_count) || 5;
  const total = Number(q.question_count) || 10;
  const content = [
    `**Round ${q.round_no} of ${rounds} · ${q.round_title}**`,
    `**Question ${q.q_no} of ${total}**`,
    "",
    String(q.prompt || ""),
    "",
    "Select the correct answer.",
    `Time left <t:${closes}:R>`,
  ].join("\n");
  const button = (key: string, word: string) => ({
    type: 2,
    style: 2,
    label: `${key.toUpperCase()}  ${String(word || "").slice(0, 72)}`.slice(0, 80),
    custom_id: `pq:${q.question_id}:${key}`,
  });
  const payload: Record<string, unknown> = {
    content,
    components: [{
      type: 1,
      components: [
        button("a", String(q.option_a || "")),
        button("b", String(q.option_b || "")),
        button("c", String(q.option_c || "")),
      ],
    }],
  };
  if (q.kind === "picture" && q.media_path) {
    payload.embeds = [{ image: { url: publicMediaUrl(String(q.media_path)) } }];
  }
  return payload;
}

async function postQuestion(token: string, channelId: string, q: Record<string, unknown>): Promise<string> {
  const payload = questionPayload(q);
  if (q.kind === "song" && q.media_path) {
    const path = String(q.media_path);
    const bytes = await downloadMedia(path);
    const name = path.split("/").pop() || "clip.mp3";
    return postMessage(token, channelId, payload, { name, bytes });
  }
  return postMessage(token, channelId, payload);
}

async function ensureHeader(
  token: string,
  channelId: string,
  quiz: Record<string, unknown>,
  roundNo: number,
  roundTitle: string,
  roundCount: number
): Promise<string> {
  const content = `**Round ${roundNo} of ${roundCount} · ${roundTitle}**`;
  const existing = String(quiz.header_message_id || "");
  if (existing && Number(quiz.current_round_no) === roundNo) return existing;
  if (existing) {
    await editMessage(token, channelId, existing, content);
    return existing;
  }
  const id = await postMessage(token, channelId, { content });
  await pinMessage(token, channelId, id);
  return id;
}

function decode64(value: string): Uint8Array {
  const bin = atob(value);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function putSample(path: string, bytes: Uint8Array, contentType: string) {
  const base = Deno.env.get("SUPABASE_URL") || "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const headers = { Authorization: `Bearer ${key}`, apikey: key };
  const existing = await fetch(`${base}/storage/v1/object/pub-quiz/${path}`, { headers });
  if (existing.ok) return;
  const sent = await fetch(`${base}/storage/v1/object/pub-quiz/${path}`, {
    method: "POST",
    headers: { ...headers, "Content-Type": contentType, "x-upsert": "true" },
    body: bytes,
  });
  if (!sent.ok) throw new Error(`Sample upload ${sent.status}`);
}

async function ensureSamples() {
  await putSample("samples/yellow-card.png", decode64(SAMPLE_PNG), "image/png");
  await putSample("samples/tone.wav", decode64(SAMPLE_WAV), "audio/wav");
}

async function runStep(db: SupabaseClient, token: string, quiz: Record<string, unknown>) {
  const id = Number(quiz.id);
  if (quiz.is_test === true) await ensureSamples();
  const starts = quiz.starts_at ? new Date(String(quiz.starts_at)).getTime() : 0;
  const now = Date.now();

  if (quiz.status === "scheduled" && starts - now > 5000) {
    let channelId = String(quiz.channel_id || "");
    if (!channelId) {
      channelId = await findPubQuizChannel(token);
      await db.rpc("gpsl_pub_quiz_runner_set_channel", {
        p_id: id,
        p_channel_id: channelId,
      });
    }
    if (!quiz.countdown_message_id) {
      const unix = Math.floor(starts / 1000);
      const messageId = await postMessage(token, channelId, {
        content: `**Pub quiz**\nStarts <t:${unix}:R> (<t:${unix}:t> UK).\nStay in this channel.`,
      });
      await db.rpc("gpsl_pub_quiz_runner_set_channel", {
        p_id: id,
        p_channel_id: channelId,
        p_countdown_message_id: messageId,
      });
    }
    await release(db, id);
    return;
  }

  let channelId = String(quiz.channel_id || "");
  if (!channelId) {
    channelId = await findPubQuizChannel(token);
    await db.rpc("gpsl_pub_quiz_runner_set_channel", {
      p_id: id,
      p_channel_id: channelId,
    });
  }

  if (quiz.status === "scheduled" || quiz.phase === "countdown") {
    await deleteMessage(token, channelId, quiz.countdown_message_id ? String(quiz.countdown_message_id) : null);
    const opened = await openAndPost(db, token, id, channelId, quiz);
    await release(db, id);
    if (opened) {
      await sleep(Math.max(0, opened));
      await selfInvoke();
    }
    return;
  }

  if (quiz.phase === "question") {
    const closes = quiz.current_question_id
      ? await questionClosesAt(db, Number(quiz.current_question_id))
      : 0;
    const wait = closes - Date.now();
    if (wait > 0) await sleep(wait);
    const closed = await db.rpc("gpsl_pub_quiz_close_question", { p_id: id });
    if (closed.error) throw new Error(closed.error.message);
    const body = closed.data as Record<string, unknown>;
    await deleteMessage(token, channelId, body.question_message_id ? String(body.question_message_id) : null);
    const endRound = !body.more_in_round;
    const title = endRound
      ? `**End of round ${body.round_no} · ${body.round_title}**`
      : `**Round ${body.round_no} · ${body.round_title} · after question ${body.q_no}**`;
    const resumeUnix = Math.floor(new Date(String(body.resume_at)).getTime() / 1000);
    const nextLine = body.finish_after
      ? "\n\nFinal table next."
      : endRound
        ? `\n\nNext round <t:${resumeUnix}:R>.`
        : `\n\nNext question <t:${resumeUnix}:R>.`;
    const boardId = await postMessage(token, channelId, {
      content: boardText(title, String(body.reveal || ""), (body.rows as Row[]) || [], null) + nextLine,
    });
    await db.rpc("gpsl_pub_quiz_mark_board", { p_id: id, p_message_id: boardId });
    await release(db, id);
    const gap = Number(body.gap_seconds) || 10;
    if (gap <= 20) {
      await sleep(gap * 1000);
      await selfInvoke();
    }
    return;
  }

  if (quiz.phase === "board" || quiz.phase === "break") {
    await deleteMessage(token, channelId, quiz.board_message_id ? String(quiz.board_message_id) : null);
    const opened = await openAndPost(db, token, id, channelId, quiz);
    await release(db, id);
    if (opened === null) return;
    if (opened > 0) {
      await sleep(opened);
      await selfInvoke();
    }
  }
}

async function questionClosesAt(db: SupabaseClient, questionId: number): Promise<number> {
  const { data, error } = await db
    .from("gpsl_pub_quiz_question")
    .select("closes_at")
    .eq("id", questionId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data?.closes_at ? new Date(data.closes_at).getTime() : 0;
}

/** Returns milliseconds to sleep before the next kick, 0 if finished, null if paid. */
async function openAndPost(
  db: SupabaseClient,
  token: string,
  quizId: number,
  channelId: string,
  quiz: Record<string, unknown>
): Promise<number | null> {
  const opened = await db.rpc("gpsl_pub_quiz_open_question", { p_id: quizId });
  if (opened.error) throw new Error(opened.error.message);
  const q = opened.data as Record<string, unknown>;
  if (q.done) {
    const paid = await db.rpc("gpsl_pub_quiz_pay", { p_id: quizId });
    if (paid.error) throw new Error(paid.error.message);
    const result = paid.data as Record<string, unknown>;
    const test = result.is_test === true;
    if (quiz.header_message_id) {
      await editMessage(
        token,
        channelId,
        String(quiz.header_message_id),
        test ? "**Test complete**" : "**Pub quiz complete**"
      );
    }
    const rows = (result.rows as Row[]) || [];
    const lines = rows.slice(0, 25).map((r) => {
      const score = `${r.place}. ${r.owner_tag || "Owner"} — ${r.points ?? 0}`;
      return test ? score : `${score} — ${money(prizeFor(Number(r.place) || 0, result))}`;
    });
    const head = test
      ? "**Test complete**\nNo prizes. These were saved questions, including any picture and song."
      : "**Final result**\nPrizes are in the Building Society.";
    await postMessage(token, channelId, {
      content: `${head}\n\n${lines.join("\n") || "No one answered."}`.slice(0, 1900),
    });
    return null;
  }
  const headerId = await ensureHeader(
    token,
    channelId,
    quiz,
    Number(q.round_no),
    String(q.round_title),
    Number(q.round_count) || 5
  );
  const messageId = await postQuestion(token, channelId, q);
  await db.rpc("gpsl_pub_quiz_mark_question_message", {
    p_question_id: q.question_id,
    p_message_id: messageId,
    p_header_message_id: headerId,
  });
  const closes = new Date(String(q.closes_at)).getTime();
  return Math.max(0, closes - Date.now());
}

async function kick() {
  const db = adminClient();
  const token = Deno.env.get("DISCORD_BOT_TOKEN") || "";
  if (!token) throw new Error("DISCORD_BOT_TOKEN missing");
  const claimed = await db.rpc("gpsl_pub_quiz_runner_claim");
  if (claimed.error) throw new Error(claimed.error.message);
  const body = claimed.data as { due?: boolean; quiz?: Record<string, unknown> };
  if (!body?.due || !body.quiz) return { due: false };
  try {
    await runStep(db, token, body.quiz);
  } catch (err) {
    console.error("pub quiz step", err);
    await release(db, Number(body.quiz.id));
    throw err;
  }
  return { due: true, quiz_id: body.quiz.id };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");
  if (!authorised(req)) return json({ error: "Unauthorized" }, 401);
  const work = kick().catch((err) => {
    console.error(err);
    return { error: err instanceof Error ? err.message : String(err) };
  });
  EdgeRuntime.waitUntil(work);
  return json({ ok: true, started: true });
});
