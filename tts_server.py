# Sulehri local server:
#   POST /            {"text": "...", "voice": "af_heart", "speed": 0.85} -> WAV audio (Kokoro voice model)
#   GET  /search?q=   -> quick web results (Google + Wikipedia in parallel, ~1-2.5 s)
import io, json, os, re, sys, threading, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor, wait

import soundfile as sf
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from kokoro_onnx import Kokoro

PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 51723
models = sys.argv[1]
# The int8 model is ~2x faster on an M1 CPU than the full one, so the voice stays ahead of the lesson.
import onnxruntime as rt
_model = os.path.join(models, "kokoro-v1.0.int8.onnx")
if not os.path.exists(_model):
    _model = os.path.join(models, "kokoro-v1.0.onnx")
_opts = rt.SessionOptions()
_opts.intra_op_num_threads = 4   # the 4 fast cores
kokoro = Kokoro.from_session(rt.InferenceSession(_model, sess_options=_opts, providers=["CPUExecutionProvider"]),
                             os.path.join(models, "voices-v1.0.bin"))
lock = threading.Lock()
cond = threading.Condition()
urgent_waiting = 0


def synth(text, voice, speed, urgent=True):
    """Lesson sentences (urgent) always go before background work like warming up the short phrases."""
    global urgent_waiting
    with cond:
        if urgent:
            urgent_waiting += 1
        else:
            cond.wait_for(lambda: urgent_waiting == 0)
    try:
        with lock:
            samples, rate = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
    finally:
        if urgent:
            with cond:
                urgent_waiting -= 1
                cond.notify_all()
    buf = io.BytesIO()
    sf.write(buf, samples, rate, format="WAV", subtype="PCM_16")
    return buf.getvalue()


pool = ThreadPoolExecutor(max_workers=6)
FILLER = re.compile(r"^(hey |hi |okay |ok |so |please |sulehri,? )*(can you |could you |please )*(tell me |explain( to me)?|teach me|show me|what('s| is| are)|how (does|do|is|are)|why (does|do|is|are)|what does)\s+", re.I)


DROP = re.compile(r"\b(means?|meaning( of)?|exactly|actually|really|please|basically|to me|for me|in simple words|simply)\b", re.I)


def clean_query(q):
    # Keep the first clause ("explain what HEAD means in git, I am confused about it" -> "HEAD in git").
    q = re.split(r"[,.;!?]| i am | i'm | because ", q.strip(), maxsplit=1, flags=re.I)[0]
    for _ in range(4):  # "explain what ..." -> strip each lead-in word in turn
        q = FILLER.sub("", q.strip()).strip(" ?.!")
        q = re.sub(r"^(what|how|why|which|who|where|when)\s+", "", q, flags=re.I)
    q = DROP.sub(" ", q)
    q = re.sub(r"^(a|an|the) ", "", q.strip(), flags=re.I)
    return re.sub(r"\s+", " ", q).strip()


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Sulehri-tutor/1.0 (local study app)"})
    with urllib.request.urlopen(req, timeout=3) as r:
        return json.load(r)


def wiki(q):
    data = get_json("https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode({
        "action": "query", "generator": "search", "gsrsearch": q, "gsrlimit": 3, "prop": "extracts|info",
        "inprop": "url", "exintro": 1, "explaintext": 1, "exsentences": 5, "format": "json"}))
    pages = sorted(data.get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 9))
    return [{"title": p["title"] + " (Wikipedia)", "url": p.get("fullurl", ""), "text": p.get("extract", "")[:700]} for p in pages]


def web(q):
    from ddgs import DDGS
    out = []
    for backend in ("google", "duckduckgo"):
        try:
            for r in DDGS().text(q, max_results=5, backend=backend):
                out.append({"title": r.get("title", ""), "url": r.get("href", ""), "text": r.get("body", "")[:400]})
            if out:
                break
        except Exception:
            pass
    return out


def search(q, deadline=3.0):
    q = clean_query(q)
    futures = [pool.submit(web, q), pool.submit(wiki, q)]
    done, _ = wait(futures, timeout=deadline)
    results = []
    for f in futures:  # Google first, then Wikipedia
        if f in done and not f.exception():
            results += f.result()
    return {"query": q, "results": results[:7]}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/search":
            q = urllib.parse.parse_qs(u.query).get("q", [""])[0]
            body = json.dumps(search(q)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        try:
            req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            data = synth(req["text"], req.get("voice", "af_heart"), float(req.get("speed", 0.85)), bool(req.get("urgent", True)))
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, *a):
        pass


def watch_parent():
    # Quit when the Sulehri app quits.
    parent = os.getppid()
    while True:
        time.sleep(2)
        if os.getppid() != parent:
            os._exit(0)


synth("Hello.", "af_heart", 1.0)  # warm up
threading.Thread(target=watch_parent, daemon=True).start()
print("READY", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
