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
  file?: { name: string; bytes: Uint8Array; type?: string }
): Promise<string> {
  let res: Response;
  if (file) {
    const form = new FormData();
    form.append("payload_json", JSON.stringify({ allowed_mentions: { parse: [] }, ...payload }));
    const kind = file.type ? { type: file.type } : undefined;
    form.append("files[0]", new Blob([file.bytes], kind), file.name);
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

async function screenIds(db: SupabaseClient): Promise<{ screen: string; audio: string }> {
  const { data } = await db
    .from("gpsl_pub_quiz_settings")
    .select("screen_message_id, audio_message_id")
    .eq("id", 1)
    .maybeSingle();
  return {
    screen: String(data?.screen_message_id || ""),
    audio: String(data?.audio_message_id || ""),
  };
}

async function saveScreen(db: SupabaseClient, screen: string, audio: string) {
  await db.from("gpsl_pub_quiz_settings").update({
    screen_message_id: screen || null,
    audio_message_id: audio || null,
    updated_at: new Date().toISOString(),
  }).eq("id", 1);
}

async function deleteMessage(token: string, channelId: string, messageId: string) {
  if (!messageId) return;
  const res = await discord(token, `/channels/${channelId}/messages/${messageId}`, { method: "DELETE" });
  if (res.status === 429) {
    await sleep(1000);
    await discord(token, `/channels/${channelId}/messages/${messageId}`, { method: "DELETE" });
  }
}

async function clearAcks(db: SupabaseClient) {
  const { data, error } = await db.rpc("gpsl_pub_quiz_take_acks");
  if (error || data == null) return;
  const rows = Array.isArray(data) ? data : [];
  for (const row of rows as { application_id?: string; interaction_token?: string }[]) {
    const app = String(row.application_id || "");
    const token = String(row.interaction_token || "");
    if (!app || !token) continue;
    const res = await fetch(`${DISCORD_API}/webhooks/${app}/${token}/messages/@original`, { method: "DELETE" });
    if (res.status === 429) await sleep(1000);
  }
}

/** One card at the bottom of the channel. The previous card is deleted first. */
async function showCard(
  db: SupabaseClient,
  token: string,
  channelId: string,
  payload: Record<string, unknown>,
  audio?: { name: string; bytes: Uint8Array; type?: string }
): Promise<string> {
  await clearAcks(db);
  const ids = await screenIds(db);
  if (ids.audio) await deleteMessage(token, channelId, ids.audio);
  if (ids.screen) await deleteMessage(token, channelId, ids.screen);
  await wipeChannel(token, channelId);
  const screen = await postMessage(token, channelId, payload);
  let audioId = "";
  if (audio) {
    audioId = await postMessage(token, channelId, { content: "**YOU HAVE TO PRESS PLAY ON THE AUDIO FILE.**" }, audio);
  }
  await saveScreen(db, screen, audioId);
  await wipeChannel(token, channelId, new Set([screen, audioId].filter(Boolean)));
  return screen;
}

const TWO_WEEKS_MS = 14 * 24 * 60 * 60 * 1000;
const DISCORD_EPOCH = 1420070400000n;

function snowflakeMs(id: string): number {
  try {
    return Number((BigInt(id) >> 22n) + DISCORD_EPOCH);
  } catch {
    return 0;
  }
}

function canWipe(type: number | undefined): boolean {
  return type == null || type === 0 || type === 19 || type === 20 || type === 21;
}

/** Empty #pub quiz, including pins. Messages in `keep` stay. */
async function wipeChannel(token: string, channelId: string, keep?: Set<string>) {
  const pins = await discord(token, `/channels/${channelId}/pins`);
  if (pins.ok) {
    const rows = (await pins.json()) as { id: string }[];
    for (const row of rows || []) {
      if (keep?.has(row.id)) continue;
      await discord(token, `/channels/${channelId}/pins/${row.id}`, { method: "DELETE" });
    }
  }
  const deadline = Date.now() + 20000;
  const skipped = new Set<string>();
  while (Date.now() < deadline) {
    const listed = await discord(token, `/channels/${channelId}/messages?limit=100`);
    if (!listed.ok) {
      console.error("pub quiz list", listed.status);
      return;
    }
    const msgs = (await listed.json()) as { id: string; type?: number }[];
    if (!Array.isArray(msgs) || msgs.length === 0) return;
    const deletable = msgs.filter((m) => m.id && !keep?.has(m.id) && !skipped.has(m.id) && canWipe(m.type));
    if (!deletable.length) return;
    const cutoff = Date.now() - TWO_WEEKS_MS;
    const recent = deletable.filter((m) => snowflakeMs(m.id) >= cutoff).map((m) => m.id);
    const older = deletable.filter((m) => snowflakeMs(m.id) < cutoff).map((m) => m.id);
    let bulkOk = false;
    if (recent.length >= 2) {
      const res = await discord(token, `/channels/${channelId}/messages/bulk-delete`, {
        method: "POST",
        body: JSON.stringify({ messages: recent.slice(0, 100) }),
      });
      bulkOk = res.ok || res.status === 204;
      if (!bulkOk) await res.text();
    }
    if (bulkOk) {
      await sleep(400);
      continue;
    }
    const batch = (recent.length ? recent : older).slice(0, 8);
    for (const id of batch) {
      const res = await discord(token, `/channels/${channelId}/messages/${id}`, { method: "DELETE" });
      if (res.status === 429) {
        await sleep(1000);
        break;
      }
      if (!(res.ok || res.status === 404)) {
        skipped.add(id);
        console.error("pub quiz delete", id, res.status);
      }
      await sleep(120);
    }
  }
}

function panel(accent: number, content: string) {
  const text = content.replace(/^(## [^\n]+)\n- /, "$1\n\n- ");
  return { type: 17, accent_color: accent, components: [{ type: 10, content: text }] };
}

function introPayload(quiz: Record<string, unknown>, startsUnix = 0) {
  const rounds = Number(quiz.play_rounds) || 5;
  const questions = Number(quiz.play_questions) || 50;
  const roundWord = rounds === 1 ? "round" : "rounds";
  const panels = quiz.is_test === true
    ? [
      panel(0xff9900, [
        "## GPSL Pub Quiz · test",
        "- Three questions",
        "- One to read, one picture, one sound",
        "- No prizes",
      ].join("\n")),
      panel(0x5865f2, [
        "## How you answer",
        "- Press **A**, **B** or **C** on the question",
        "- Owners only",
        "- Link your Discord account on GPSL first, or the button does not count",
        "- You can change your answer until the clock ends",
        "- Being first does not matter",
      ].join("\n")),
      panel(0x57f287, [
        "## The clock",
        "- 10 to 14 seconds",
        "- A longer question gets the longer clock",
        "- The time on the question counts down",
        "- When it ends, this channel is cleared",
        "- You see the answer, then only the next question",
      ].join("\n")),
    ]
    : [
      panel(0xff9900, [
        "## GPSL Pub Quiz",
        "- Owners only, in this channel",
        "- Link your Discord account on GPSL before you press a button, or the answer does not count",
      ].join("\n")),
      panel(0x5865f2, [
        "## How you answer",
        "- Each question is **A**, **B** or **C**",
        "- Press one button on that message",
        "- One answer each",
        "- You can change it until the clock ends",
        "- Being first does not score extra",
        "- A right answer is one point",
      ].join("\n")),
      panel(0x57f287, [
        "## The clock",
        "- You get 10 to 14 seconds",
        "- A longer question gets the longer clock",
        "- Everyone has the same time",
        "- The time on the question counts down",
        "- When it ends, this channel is cleared",
        "- The answer and the table go up on their own",
        "- About 10 seconds between questions, and about a minute between rounds",
      ].join("\n")),
      panel(0xfee75c, [
        "## The sheet and the prizes",
        `- ${rounds} ${roundWord}, ${questions} questions`,
        `- Prizes go to your Building Society`,
        `- 1st ${money(prizeFor(1, quiz))}`,
        `- 2nd ${money(prizeFor(2, quiz))}`,
        `- 3rd ${money(prizeFor(3, quiz))}`,
        `- Anyone else who answers at least once gets ${money(prizeFor(4, quiz))}`,
        "- A tie shares that place. The next score takes the next place",
        "- The same table is on GPSL: Owners → Games → Pub Quiz",
      ].join("\n")),
    ];
  if (startsUnix > 0) {
    panels.push(panel(0xeb459e, [
      "## Doors are open",
      `- First question <t:${startsUnix}:R> (<t:${startsUnix}:t> UK)`,
      "- This card becomes the first question",
    ].join("\n")));
  }
  return { flags: 32768, components: panels };
}

function noteCard(accent: number, content: string) {
  return { flags: 32768, components: [panel(accent, content)] };
}

async function postIntro(
  db: SupabaseClient,
  token: string,
  channelId: string,
  quiz: Record<string, unknown>,
  startsUnix = 0
) {
  const summary = await db.rpc("gpsl_pub_quiz_ready_summary", { p_id: Number(quiz.id) });
  const ready = (summary.data || {}) as Record<string, unknown>;
  const shown = {
    ...quiz,
    play_rounds: Number(ready.rounds) || 5,
    play_questions: Number(ready.questions) || 50,
  };
  return showCard(db, token, channelId, introPayload(shown, startsUnix));
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

function clockLine(q: Record<string, unknown>, seconds: number, lead: string): string {
  const closes = q.closes_at ? new Date(String(q.closes_at)).getTime() : 0;
  if (!closes) return `${lead}**${seconds} seconds**.`;
  const unix = Math.floor(closes / 1000);
  return `${lead}**<t:${unix}:R>**.`;
}

function questionPayload(q: Record<string, unknown>) {
  const rounds = Number(q.round_count) || 5;
  const total = Number(q.question_count) || 10;
  const seconds = Number(q.answer_seconds) || 12;
  const button = (key: string, word: string, style: number) => ({
    type: 2,
    style,
    label: `${key.toUpperCase()}   ${String(word || "").slice(0, 70)}`.slice(0, 80),
    custom_id: `pq:${q.question_id}:${key}`,
  });
  const parts: Record<string, unknown>[] = [
    { type: 10, content: `## Round ${q.round_no} of ${rounds}\n${q.round_title}` },
    { type: 14, divider: true, spacing: 1 },
    { type: 10, content: `### Question ${q.q_no} of ${total}\n\n${String(q.prompt || "")}` },
  ];
  if (q.kind === "picture" && q.media_path) {
    parts.push({
      type: 12,
      items: [{ media: { url: publicMediaUrl(String(q.media_path)) } }],
    });
  }
  parts.push(
    { type: 14, divider: true, spacing: 1 },
    { type: 10, content: clockLine(q, seconds, q.kind === "song" ? "**YOU HAVE TO PRESS PLAY ON THE AUDIO FILE.** You have " : "You have ") },
    {
      type: 1,
      components: [
        button("a", String(q.option_a || ""), 1),
        button("b", String(q.option_b || ""), 3),
        button("c", String(q.option_c || ""), 4),
      ],
    },
  );
  return {
    flags: 32768,
    components: [{ type: 17, accent_color: 0xff9900, components: parts }],
  };
}

function audioType(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase() || "";
  if (ext === "mp3") return "audio/mpeg";
  if (ext === "wav") return "audio/wav";
  if (ext === "ogg") return "audio/ogg";
  if (ext === "m4a") return "audio/mp4";
  if (ext === "flac") return "audio/flac";
  return "application/octet-stream";
}

async function showQuestion(
  db: SupabaseClient,
  token: string,
  channelId: string,
  q: Record<string, unknown>
): Promise<string> {
  if (q.kind === "song" && q.media_path) {
    const path = String(q.media_path);
    const bytes = await downloadMedia(path);
    const name = path.split("/").pop() || "clip.mp3";
    return showCard(db, token, channelId, questionPayload(q), { name, bytes, type: audioType(name) });
  }
  return showCard(db, token, channelId, questionPayload(q));
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
      const messageId = await postIntro(db, token, channelId, quiz, unix);
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
    if (!quiz.countdown_message_id) {
      await postIntro(db, token, channelId, quiz);
      await sleep(25000);
    }
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
    const wait = closes + 5000 - Date.now();
    if (wait > 0) await sleep(wait);
    const closed = await db.rpc("gpsl_pub_quiz_close_question", { p_id: id });
    if (closed.error) throw new Error(closed.error.message);
    const body = closed.data as Record<string, unknown>;
    const endRound = !body.more_in_round;
    const title = endRound
      ? `End of round ${body.round_no} · ${body.round_title}`
      : `Answer · round ${body.round_no} · question ${body.q_no}`;
    const gap = Number(body.gap_seconds) || 10;
    const rows = (body.rows as Row[]) || [];
    const scores = rows.slice(0, 25).map((r) => `${r.place}. ${r.owner_tag || "Owner"} — ${r.points ?? 0}`);
    const extra = rows.length > 25 ? `\n… and ${rows.length - 25} more` : "";
    const nextLine = body.finish_after
      ? "Final table next."
      : endRound
        ? "Next round in one minute."
        : `Next question in ${gap} seconds.`;
    const boardId = await showCard(db, token, channelId, noteCard(
      0x57f287,
      [
        `## ${title}`,
        "",
        `Correct answer: ${String(body.reveal || "")}`,
        "",
        scores.length ? scores.join("\n") + extra : "No answers yet.",
        "",
        nextLine,
      ].join("\n"),
    ));
    await db.rpc("gpsl_pub_quiz_mark_board", { p_id: id, p_message_id: boardId });
    await release(db, id);
    if (gap <= 70) {
      await sleep(gap * 1000);
      await selfInvoke();
    }
    return;
  }

  if (quiz.phase === "board" || quiz.phase === "break") {
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
    const rows = (result.rows as Row[]) || [];
    const lines = rows.slice(0, 25).map((r) => {
      const score = `${r.place}. ${r.owner_tag || "Owner"} — ${r.points ?? 0}`;
      return test ? score : `${score} — ${money(prizeFor(Number(r.place) || 0, result))}`;
    });
    const head = test
      ? "## Test complete\n\nNo prizes. These were saved questions, including any picture and song."
      : "## Final result\n\nPrizes are in the Building Society.";
    await showCard(db, token, channelId, noteCard(
      0xfee75c,
      `${head}\n\n${lines.join("\n") || "No one answered."}`.slice(0, 1900),
    ));
    return null;
  }
  const messageId = await showQuestion(db, token, channelId, q);
  await db.rpc("gpsl_pub_quiz_mark_question_message", {
    p_question_id: q.question_id,
    p_message_id: messageId,
    p_header_message_id: null,
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
