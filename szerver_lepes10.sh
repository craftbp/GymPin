cd /opt/tricfit/pocketbase
sudo tee pb_hooks/ai.pb.js >/dev/null <<'EOF'
/// <reference path="../pb_data/types.d.ts" />
// TricFit – AI training analysis.
// The app computes an anonymous summary of the last 4 weeks (no name, no e-mail) and posts it here.
// The server adds the instructions, calls the AI provider (Groq by default, any OpenAI-compatible API),
// saves the answer in ai_reports and returns it. The API key never leaves the server.
//
// Settings (environment variables, file /opt/tricfit/pocketbase/.env):
//   GROQ_API_KEY     the key from console.groq.com (required)
//   AI_MODEL         default: openai/gpt-oss-120b  (if it is retired, the fallbacks below are tried)
//   AI_URL           default: https://api.groq.com/openai/v1/chat/completions
//   AI_DAILY_LIMIT   analyses per user per day, default: 3

routerAdd("POST", "/api/tricfit/analyze", (e) => {
  const lang0 = ((e.requestInfo().body || {}).lang === "en") ? "en" : "hu";
  const msg = (hu, en) => lang0 === "en" ? en : hu;
  const key = $os.getenv("GROQ_API_KEY") || $os.getenv("AI_API_KEY");
  if (!key || key.indexOf("ide_masold") === 0) return e.json(503, { message: msg("Az AI-elemzés még nincs beállítva a szerveren (hiányzik a GROQ_API_KEY).", "AI analysis is not set up on the server yet (missing GROQ_API_KEY).") });
  const model0 = $os.getenv("AI_MODEL") || "openai/gpt-oss-120b";
  const url = $os.getenv("AI_URL") || "https://api.groq.com/openai/v1/chat/completions";
  const limit = parseInt($os.getenv("AI_DAILY_LIMIT") || "3", 10) || 3;

  const user = e.auth;
  const body = e.requestInfo().body || {};
  const summary = body.summary;
  const lang = body.lang === "en" ? "en" : "hu";
  const raw = JSON.stringify(summary || {});
  if (!summary || raw.length < 20) return e.json(400, { message: msg("Nincs elemezhető edzésadat.", "No training data to analyse.") });
  if (raw.length > 25000) return e.json(400, { message: msg("Túl sok adat az elemzéshez.", "Too much data to analyse.") });

  // daily limit (UTC day)
  const today = new DateTime().string().slice(0, 10) + " 00:00:00.000Z";
  const used = e.app.findRecordsByFilter("ai_reports", "user = {:u} && created >= {:d}", "", 0, 0, { u: user.id, d: today }).length;
  if (used >= limit) return e.json(429, { message: lang === "en" ? `Daily limit reached (${limit} analyses). Try again tomorrow.` : `Elérted a napi keretet (${limit} elemzés). Holnap újra kérhetsz.` });

  const sys = lang === "en"
    ? "You are an experienced strength & conditioning coach. You analyse a lifter's last 4 weeks of training from the JSON summary provided by the TricFit app. " +
      "Use ONLY the data given; do not invent numbers. Be concrete (name exercises, weights, sets). Do not give medical advice; if something suggests pain or injury risk, advise seeing a professional. " +
      "Answer in English, max. 250 words, in this structure: **Summary** (2-3 sentences), **What goes well** (1-3 bullets), **Suggestions for next week** (3-5 concrete bullets, e.g. +2.5 kg on X, add 2 sets for Y, deload), **Watch out** (only if needed). Use '- ' for bullets."
    : "Tapasztalt erőnléti edző vagy. A TricFit app által küldött JSON-összesítő alapján elemzed egy sportoló elmúlt 4 heti edzéseit. " +
      "CSAK a kapott adatokból dolgozz, ne találj ki számokat. Legyél konkrét (gyakorlatnév, súly, sorozatszám). Ne adj orvosi tanácsot; ha valami fájdalomra vagy sérülésveszélyre utal, javasold szakember felkeresését. " +
      "Válaszolj természetes, helyes magyarsággal, tegezve, legfeljebb 250 szóban, ebben a szerkezetben: **Összegzés** (2-3 mondat), **Ami jól megy** (1-3 pont), **Javaslatok a következő hétre** (3-5 konkrét pont, pl. +2,5 kg X-en, +2 sorozat Y-ra, könnyített hét), **Figyelj oda** (csak ha szükséges). A pontokat '- ' jellel kezdd. Tizedesvessző, magyar mértékegységek.";
  const userMsg = lang === "en"
    ? "Training summary (JSON):\n" + raw + "\n\nAnswer in English."
    : "Edzésösszesítő (JSON):\n" + raw + "\n\nFONTOS: a teljes választ MAGYARUL írd, ezekkel a fejlécekkel: **Összegzés**, **Ami jól megy**, **Javaslatok a következő hétre**, **Figyelj oda**. A gyakorlatneveket is magyarul használd, ha az összesítőben magyarul szerepelnek.";
  const models = [model0, "openai/gpt-oss-120b", "openai/gpt-oss-20b"].filter((m, i, a) => m && a.indexOf(m) === i);

  let res = null, model = model0;
  for (let i = 0; i < models.length; i++) {
    model = models[i];
    const req = { model: model, temperature: 0.4, max_tokens: 2000,
      messages: [{ role: "system", content: sys }, { role: "user", content: userMsg }] };
    if (model.indexOf("gpt-oss") >= 0) req.reasoning_effort = "low";      // gpt-oss thinks first; keep it short
    try {
      res = $http.send({ url: url, method: "POST", timeout: 90, body: JSON.stringify(req),
        headers: { "Authorization": "Bearer " + key, "Content-Type": "application/json" } });
    } catch (err) {
      e.app.logger().error("TricFit AI request failed", "error", String(err), "model", model);
      return e.json(502, { message: msg("Az AI-szolgáltató most nem érhető el. Próbáld újra később.", "The AI service is not reachable right now. Try again later.") });
    }
    if (res.statusCode === 404 || (res.statusCode === 400 && /model/i.test(String(res.raw || "")))) {
      e.app.logger().warn("TricFit AI model not available, trying the next one", "model", model, "body", String(res.raw || "").slice(0, 300));
      continue;                                    // retired / unknown model -> next fallback
    }
    break;
  }
  if (!res || res.statusCode !== 200) {
    const st = res ? res.statusCode : 0;
    e.app.logger().error("TricFit AI error", "status", st, "model", model, "body", String((res && res.raw) || "").slice(0, 500));
    return e.json(502, { message: st === 429
      ? msg("Az AI-szolgáltató most túlterhelt (ingyenes keret). Próbáld újra pár perc múlva.", "The AI service is busy (free tier). Try again in a few minutes.")
      : st === 401 ? msg("Hibás AI-kulcs a szerveren (GROQ_API_KEY).", "Invalid AI key on the server (GROQ_API_KEY).")
      : msg("Az AI-elemzés most nem sikerült (" + st + ").", "The AI analysis failed (" + st + ").") });
  }
  const text = String(((((res.json || {}).choices || [])[0] || {}).message || {}).content || "").replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  if (!text) return e.json(502, { message: msg("Az AI üres választ adott. Próbáld újra.", "The AI returned an empty answer. Try again.") });

  const r = new Record(e.app.findCollectionByNameOrId("ai_reports"));
  r.set("user", user.id); r.set("text", text.slice(0, 8000)); r.set("lang", lang); r.set("model", model); r.set("summary", summary);
  e.app.save(r);
  return e.json(200, { id: r.id, text: r.getString("text"), created: r.getString("created"), remaining: Math.max(0, limit - used - 1) });
}, $apis.requireAuth("users"));
EOF
sudo docker restart tricfit-pb
sleep 3; sudo docker logs --tail 3 tricfit-pb
