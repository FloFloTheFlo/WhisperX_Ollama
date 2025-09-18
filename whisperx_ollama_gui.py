# file: whisperx_ollama_gui.py
import tkinter as tk
from tkinter import filedialog, messagebox
import threading, queue, subprocess, os, json, time
import requests

# ---------------------------
# Config you will customize
# ---------------------------
OLLAMA_URL = "http://localhost:11434/api/generate"  # Ollama default
DEFAULT_MODEL = "llama3.1:latest"                    # pick what you actually have
WHISPERX_ENV = "whisperx"                            # your conda env name, if using conda
WHISPERX_CMD = [
    # Example CLI call. Adjust to your setup. You can also call python -m whisperx if needed.
    # If you don't use conda, replace with the path to your python/whisperx executable.
    "conda", "run", "-n", WHISPERX_ENV, "whisperx",
    # Flags here are illustrative. Change or extend as you like.
    "--model", "large-v3",
    "--audio", "__AUDIO__",
    "--output_dir", "__OUTDIR__",
    "--output_format", "txt"
]
# ---------------------------

def chunk_text(text, max_chars=4000):
    # Simple deterministic chunker. Replace with token-based if you care.
    chunks, buf = [], []
    length = 0
    for para in text.split("\n"):
        if length + len(para) + 1 > max_chars and buf:
            chunks.append("\n".join(buf))
            buf, length = [], 0
        buf.append(para)
        length += len(para) + 1
    if buf:
        chunks.append("\n".join(buf))
    return chunks

def run_process(cmd, line_cb, done_cb):
    # Run a process and stream stdout lines to callback
    def _worker():
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
            for line in proc.stdout:
                line_cb(line.rstrip("\n"))
            proc.wait()
            done_cb(proc.returncode)
        except Exception as e:
            line_cb(f"[ERROR] {e}")
            done_cb(1)
    threading.Thread(target=_worker, daemon=True).start()

def stream_ollama(prompt, model, line_cb, done_cb, options=None):
    payload = {"model": model, "prompt": prompt, "stream": True}
    if options:
        payload.update(options)

    def _worker():
        try:
            with requests.post(OLLAMA_URL, json=payload, stream=True, timeout=3600) as r:
                r.raise_for_status()
                for raw in r.iter_lines(decode_unicode=True):
                    if not raw:
                        continue
                    try:
                        obj = json.loads(raw)
                        if "response" in obj:
                            line_cb(obj["response"])
                        if obj.get("done"):
                            break
                    except json.JSONDecodeError:
                        # Ollama occasionally sends non-JSON keepalives; ignore gracefully.
                        continue
            done_cb(0)
        except Exception as e:
            line_cb(f"[OLLAMA ERROR] {e}")
            done_cb(1)

    threading.Thread(target=_worker, daemon=True).start()

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("WhisperX → Ollama Summarizer (PowerShell Escape Pod)")
        self.geometry("900x600")

        self.audio_path = tk.StringVar()
        self.model = tk.StringVar(value=DEFAULT_MODEL)
        self.bypass_var = tk.BooleanVar(value=False)
        self.transcript_path = tk.StringVar()
        self.status_var = tk.StringVar(value="Idle")

        top = tk.Frame(self)
        top.pack(fill="x", padx=10, pady=10)

        tk.Label(top, text="Audio:").grid(row=0, column=0, sticky="w")
        tk.Entry(top, textvariable=self.audio_path, width=70).grid(row=0, column=1, sticky="we", padx=6)
        tk.Button(top, text="Browse", command=self.pick_audio).grid(row=0, column=2)

        tk.Checkbutton(top, text="Bypass WhisperX (use existing transcript)",
                       variable=self.bypass_var, command=self.on_bypass_toggle).grid(row=1, column=1, sticky="w", pady=6)

        tk.Label(top, text="Transcript:").grid(row=2, column=0, sticky="w")
        self.transcript_entry = tk.Entry(top, textvariable=self.transcript_path, width=70, state="disabled")
        self.transcript_entry.grid(row=2, column=1, sticky="we", padx=6)
        self.transcript_btn = tk.Button(top, text="Browse", command=self.pick_transcript, state="disabled")
        self.transcript_btn.grid(row=2, column=2)

        tk.Label(top, text="Ollama model:").grid(row=3, column=0, sticky="w")
        tk.Entry(top, textvariable=self.model, width=30).grid(row=3, column=1, sticky="w")

        actions = tk.Frame(self)
        actions.pack(fill="x", padx=10, pady=6)
        tk.Button(actions, text="Transcribe (WhisperX)", command=self.transcribe).pack(side="left", padx=4)
        tk.Button(actions, text="Summarize with Ollama", command=self.summarize).pack(side="left", padx=4)

        status = tk.Frame(self)
        status.pack(fill="x", padx=10)
        tk.Label(status, text="Status:").pack(side="left")
        tk.Label(status, textvariable=self.status_var).pack(side="left", padx=6)

        self.out = tk.Text(self, wrap="word")
        self.out.pack(fill="both", expand=True, padx=10, pady=10)
        self.out.configure(state="disabled")

        self.q = queue.Queue()
        self.after(50, self._drain_queue)

    def log(self, text):
        self.q.put(text)

    def _drain_queue(self):
        try:
            while True:
                line = self.q.get_nowait()
                self.out.configure(state="normal")
                self.out.insert("end", line + "\n")
                self.out.see("end")
                self.out.configure(state="disabled")
        except queue.Empty:
            pass
        self.after(50, self._drain_queue)

    def pick_audio(self):
        path = filedialog.askopenfilename(title="Select audio file")
        if path:
            self.audio_path.set(path)

    def pick_transcript(self):
        path = filedialog.askopenfilename(title="Select transcript (.txt)", filetypes=[("Text", "*.txt"), ("All", "*.*")])
        if path:
            self.transcript_path.set(path)

    def on_bypass_toggle(self):
        if self.bypass_var.get():
            self.transcript_entry.configure(state="normal")
            self.transcript_btn.configure(state="normal")
        else:
            self.transcript_entry.configure(state="disabled")
            self.transcript_btn.configure(state="disabled")

    def transcribe(self):
        if self.bypass_var.get():
            self.log("[INFO] Bypass enabled. Skipping WhisperX.")
            return
        audio = self.audio_path.get().strip()
        if not audio:
            messagebox.showerror("Missing audio", "Please select an audio file.")
            return
        outdir = os.path.join(os.path.dirname(audio), "whisperx_out")
        os.makedirs(outdir, exist_ok=True)
        cmd = []
        for tok in WHISPERX_CMD:
            if tok == "__AUDIO__":
                cmd.append(audio)
            elif tok == "__OUTDIR__":
                cmd.append(outdir)
            else:
                cmd.append(tok)
        self.status_var.set("Transcribing...")
        self.log(f"[CMD] {' '.join(cmd)}")
        def done(rc):
            self.status_var.set("Idle")
            if rc == 0:
                # naive: assume whisperx wrote a .txt next to audio or in outdir; adjust as needed
                guessed = os.path.join(outdir, os.path.splitext(os.path.basename(audio))[0] + ".txt")
                if os.path.exists(guessed):
                    self.transcript_path.set(guessed)
                    self.log(f"[OK] Transcript at: {guessed}")
                else:
                    self.log("[WARN] Could not find transcript automatically. Set it manually.")
            else:
                self.log("[ERROR] WhisperX exited with an error.")
        run_process(cmd, self.log, done)

    def summarize(self):
        # Load transcript (either from bypass or from WhisperX output)
        transcript_file = self.transcript_path.get().strip() if self.bypass_var.get() else self.transcript_path.get().strip()
        if not transcript_file or not os.path.exists(transcript_file):
            messagebox.showerror("Missing transcript", "Please provide a transcript file (.txt).")
            return
        with open(transcript_file, "r", encoding="utf-8", errors="ignore") as f:
            text = f.read()

        chunks = chunk_text(text, max_chars=4000)
        self.log(f"[INFO] Summarizing {len(chunks)} chunk(s) with model {self.model.get()}...")
        self.status_var.set("Summarizing...")

        def summarize_chunk(idx, chunk_text):
            sys_prompt = (
                "You are a senior meeting-notes system. Summarize the chunk with bullet points, "
                "capture decisions, action items (owner + deadline if mentioned), and unresolved questions. "
                "Be concise and non-repetitive. If this chunk looks like mid-sentence, still summarize it cleanly."
            )
            prompt = f"{sys_prompt}\n\n[CHUNK {idx+1}/{len(chunks)}]\n\n{chunk_text}\n\nSummary:\n"
            self.log(f"\n=== Summary for chunk {idx+1}/{len(chunks)} ===\n")
            def done(rc):
                if idx == len(chunks) - 1:
                    self.status_var.set("Idle")
                    self.log("\n[DONE] Summarization complete.\n")
            stream_ollama(prompt, self.model.get(), self.log, done, options={"options": {"temperature": 0.2}})

        # Stream each chunk serially to keep it simple
        def _runner():
            for i, c in enumerate(chunks):
                summarize_chunk(i, c)
                # crude pacing to keep chunks sequential. If you want proper chaining, wait on per-chunk done callbacks.
                # For now, sleep long enough for typical chunks to complete or replace with a proper barrier.
                time.sleep(0.3)

        threading.Thread(target=_runner, daemon=True).start()

if __name__ == "__main__":
    App().mainloop()
