"""Kaalu Live Transcriber

Real-time call transcription overlay for any VOIP app (Zoom, Slack, Teams,
browser). Captures your microphone [Me] and system audio loopback [Them]
via WASAPI, transcribes with a cloud STT API (auto language detection),
and can translate each line into a chosen language.
"""
import io
import json
import os
import queue
import struct
import threading
import time
import wave
from datetime import datetime

import requests
import pyaudiowpatch as pyaudio

import tkinter as tk
from tkinter import ttk, messagebox, simpledialog
from tkinter.scrolledtext import ScrolledText

KAALU_DIR = os.path.join(os.path.expanduser("~"), "Kaalu")
CONFIG_PATH = os.path.join(KAALU_DIR, "transcribe_config.json")
TRANSCRIPT_DIR = os.path.join(KAALU_DIR, "Transcripts")
BG = "#1b1e26"
BG2 = "#242834"
FG = "#e8e8e8"
ACCENT = "#3f8cff"

DEFAULT_CONFIG = {
    "api_key": "",
    "base_url": "https://api.openai.com/v1",
    "stt_model": "gpt-4o-mini-transcribe",
    "stt_fallback_model": "whisper-1",
    "chat_model": "gpt-4o-mini",
    "silence_threshold": 300,
    "silence_end_sec": 0.8,
    "max_segment_sec": 7.0,
    "min_segment_sec": 0.35,
    "font_size": 11,
    "geometry": "620x400+100+100",
}

LANGS = ["None (original)", "English", "Hindi", "Spanish", "French", "Telugu",
         "Tamil", "Bengali", "Kannada", "Odia", "Bhojpuri", "Chinese",
         "Japanese", "Latin", "Greek", "Sanskrit", "Punjabi", "Gujarati",
         "Haryanvi", "Nepali"]


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    if not cfg.get("api_key"):
        cfg["api_key"] = os.environ.get("OPENAI_API_KEY", "")
    return cfg


def save_config(cfg):
    os.makedirs(KAALU_DIR, exist_ok=True)
    out = {k: v for k, v in cfg.items() if k in DEFAULT_CONFIG}
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)


def rms16(data):
    n = len(data) // 2
    if n == 0:
        return 0.0
    samples = struct.unpack("<%dh" % n, data[:n * 2])
    return (sum(s * s for s in samples) / n) ** 0.5


class CaptureThread(threading.Thread):
    def __init__(self, app, device_info, label):
        super().__init__(daemon=True)
        self.app = app
        self.dev = device_info
        self.label = label
        self.rate = int(self.dev["defaultSampleRate"])
        self.channels = max(1, int(self.dev["maxInputChannels"]))

    def _open(self, channels, fpb):
        return self.app.pa.open(format=pyaudio.paInt16, channels=channels,
                                rate=self.rate, input=True,
                                input_device_index=self.dev["index"],
                                frames_per_buffer=fpb)

    def run(self):
        app = self.app
        cfg = app.cfg
        fpb = max(256, int(self.rate * 0.05))
        want = self.channels
        if not self.dev.get("isLoopbackDevice"):
            want = min(want, 2)
        stream, err = None, None
        for c in (want, self.channels):
            try:
                stream = self._open(c, fpb)
                self.channels = c
                break
            except Exception as e:
                err = e
        if stream is None:
            app.ui_q.put(("status", "%s audio failed: %s" % (self.label, err)))
            return
        buf, preroll = [], []
        seg_start = last_voice = None
        thr = float(cfg["silence_threshold"])
        while not app.stop_event.is_set():
            try:
                data = stream.read(fpb, exception_on_overflow=False)
            except Exception:
                time.sleep(0.05)
                continue
            if app.paused:
                buf, preroll = [], []
                seg_start = last_voice = None
                continue
            now = time.time()
            level = rms16(data)
            if seg_start is None:
                preroll.append(data)
                if len(preroll) > 8:
                    preroll.pop(0)
                if level > thr:
                    seg_start = last_voice = now
                    buf = list(preroll)
            else:
                buf.append(data)
                if level > thr:
                    last_voice = now
                if (now - last_voice) >= cfg["silence_end_sec"] or \
                        (now - seg_start) >= cfg["max_segment_sec"]:
                    if (last_voice - seg_start) >= cfg["min_segment_sec"]:
                        app.submit_segment(self.label, seg_start,
                                           b"".join(buf), self.rate,
                                           self.channels)
                    buf, preroll = [], []
                    seg_start = last_voice = None
        if seg_start is not None and buf and \
                (last_voice - seg_start) >= cfg["min_segment_sec"]:
            app.submit_segment(self.label, seg_start, b"".join(buf),
                               self.rate, self.channels)
        try:
            stream.stop_stream()
            stream.close()
        except Exception:
            pass


class TranscriberApp:
    def __init__(self):
        self.cfg = load_config()
        self.running = False
        self.paused = False
        self.stop_event = threading.Event()
        self.work_q = queue.Queue()
        self.ui_q = queue.Queue()
        self.pending = 0
        self.pending_lock = threading.Lock()
        self.lines = []
        self.pa = None
        self.threads = []
        self.stt_model = self.cfg["stt_model"]
        self.session_start = None
        self.target_lang = LANGS[0]
        self._build_ui()
        self.root.after(120, self._poll)

    def _build_ui(self):
        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        try:
            self.root.attributes("-alpha", 0.95)
        except Exception:
            pass
        self.root.configure(bg=BG)
        self.root.geometry(self.cfg.get("geometry", "620x400+100+100"))
        bar = tk.Frame(self.root, bg=BG2, height=34)
        bar.pack(fill="x", side="top")
        bar.bind("<ButtonPress-1>", self._move_press)
        bar.bind("<B1-Motion>", self._move_drag)
        title = tk.Label(bar, text="  Kaalu Live Transcriber", bg=BG2, fg=FG,
                         font=("Segoe UI", 10, "bold"))
        title.pack(side="left", pady=4)
        title.bind("<ButtonPress-1>", self._move_press)
        title.bind("<B1-Motion>", self._move_drag)

        def btn(txt, cmd):
            return tk.Button(bar, text=txt, command=cmd, width=3, bd=0,
                             bg=BG2, fg=FG, activebackground=ACCENT,
                             activeforeground="white", font=("Segoe UI", 10))

        self.close_btn = btn("✕", self.on_close)
        self.close_btn.pack(side="right", padx=(0, 6))
        self.stop_btn = btn("⏹", self.on_stop)
        self.stop_btn.pack(side="right")
        self.play_btn = btn("▶", self.on_play_pause)
        self.play_btn.pack(side="right")
        btn("A+", lambda: self._font(+1)).pack(side="right")
        btn("A-", lambda: self._font(-1)).pack(side="right")
        row = tk.Frame(self.root, bg=BG)
        row.pack(fill="x", side="top", padx=8, pady=(4, 0))
        self.status_var = tk.StringVar(value="Idle — press ▶ to start")
        tk.Label(row, textvariable=self.status_var, bg=BG, fg="#9aa4b2",
                 font=("Segoe UI", 9)).pack(side="left")
        self.lang_var = tk.StringVar(value=LANGS[0])
        self.lang_box = ttk.Combobox(row, textvariable=self.lang_var,
                                     values=LANGS, state="readonly", width=14)
        self.lang_box.pack(side="right")
        self.lang_box.bind("<<ComboboxSelected>>", self._on_lang)
        tk.Label(row, text="Translate:", bg=BG, fg="#9aa4b2",
                 font=("Segoe UI", 9)).pack(side="right", padx=(0, 4))
        fs = int(self.cfg.get("font_size", 11))
        self.text = ScrolledText(self.root, bg=BG, fg=FG, bd=0, wrap="word",
                                 font=("Segoe UI", fs), insertbackground=FG,
                                 padx=10, pady=8)
        self.text.pack(fill="both", expand=True, padx=4, pady=4)
        self.text.tag_config("me", foreground="#7fd4ff")
        self.text.tag_config("them", foreground="#ffb86c")
        self.text.tag_config("tr", foreground="#8be98b",
                             font=("Segoe UI", fs, "italic"))
        self.text.tag_config("meta", foreground="#8a93a3")
        self.text.configure(state="disabled")
        grip = tk.Label(self.root, text="◢", bg=BG, fg="#5a6472",
                        cursor="size_nw_se")
        grip.place(relx=1.0, rely=1.0, anchor="se")
        grip.bind("<ButtonPress-1>", self._grip_press)
        grip.bind("<B1-Motion>", self._grip_drag)

    def _on_lang(self, event=None):
        self.target_lang = self.lang_var.get()

    def _move_press(self, e):
        self._mx, self._my = e.x_root, e.y_root
        self._wx, self._wy = self.root.winfo_x(), self.root.winfo_y()

    def _move_drag(self, e):
        x = self._wx + e.x_root - self._mx
        y = self._wy + e.y_root - self._my
        self.root.geometry("+%d+%d" % (x, y))

    def _grip_press(self, e):
        self._gx, self._gy = e.x_root, e.y_root
        self._gw = self.root.winfo_width()
        self._gh = self.root.winfo_height()

    def _grip_drag(self, e):
        w = max(380, self._gw + e.x_root - self._gx)
        h = max(220, self._gh + e.y_root - self._gy)
        self.root.geometry("%dx%d" % (w, h))

    def _font(self, delta):
        fs = max(7, min(28, int(self.cfg.get("font_size", 11)) + delta))
        self.cfg["font_size"] = fs
        self.text.configure(font=("Segoe UI", fs))
        self.text.tag_config("tr", font=("Segoe UI", fs, "italic"))

    def on_play_pause(self):
        if not self.running:
            self._start_session()
        elif self.paused:
            self.paused = False
            self.play_btn.config(text="⏸")
            self.status_var.set("● Recording")
        else:
            self.paused = True
            self.play_btn.config(text="▶")
            self.status_var.set("Paused")

    def _ensure_key(self):
        if self.cfg.get("api_key"):
            return True
        key = simpledialog.askstring(
            "OpenAI API key",
            "Paste your OpenAI API key (stored in transcribe_config.json):",
            show="*", parent=self.root)
        if key:
            self.cfg["api_key"] = key.strip()
            save_config(self.cfg)
            return True
        messagebox.showwarning(
            "Kaalu", "An API key is required for cloud transcription.",
            parent=self.root)
        return False

    def _start_session(self):
        if not self._ensure_key():
            return
        try:
            self.pa = pyaudio.PyAudio()
            w = self.pa.get_host_api_info_by_type(pyaudio.paWASAPI)
            mic = self.pa.get_device_info_by_index(w["defaultInputDevice"])
            spk = self.pa.get_device_info_by_index(w["defaultOutputDevice"])
            if not spk.get("isLoopbackDevice"):
                for lb in self.pa.get_loopback_device_info_generator():
                    if spk["name"] in lb["name"]:
                        spk = lb
                        break
        except Exception as e:
            messagebox.showerror("Kaalu", "Audio device error: %s" % e,
                                 parent=self.root)
            return
        self.stop_event = threading.Event()
        self.work_q = queue.Queue()
        self.lines = []
        with self.pending_lock:
            self.pending = 0
        self.session_start = datetime.now()
        self.stt_model = self.cfg["stt_model"]
        self._clear_text()
        self._append_meta("Session %s — Mic: %s | System: %s" % (
            self.session_start.strftime("%H:%M:%S"), mic["name"],
            spk["name"]))
        self.threads = [CaptureThread(self, mic, "Me"),
                        CaptureThread(self, spk, "Them")]
        for _ in range(3):
            t = threading.Thread(target=self._stt_worker, daemon=True)
            t.start()
        for t in self.threads[:2]:
            t.start()
        self.running = True
        self.paused = False
        self.play_btn.config(text="⏸")
        self.status_var.set("● Recording")

    def on_stop(self):
        if not self.running:
            return
        self.paused = False
        self.stop_event.set()
        self.status_var.set("Finishing pending audio…")
        self._stop_deadline = time.time() + 10
        self.root.after(250, self._finish_stop)

    def _finish_stop(self):
        with self.pending_lock:
            busy = self.pending
        if busy > 0 and time.time() < self._stop_deadline:
            self.root.after(300, self._finish_stop)
            return
        self._drain_ui()
        self.running = False
        self.play_btn.config(text="▶")
        self.status_var.set("Stopped — Idle")
        try:
            if self.pa:
                self.pa.terminate()
        except Exception:
            pass
        self.pa = None
        if self.lines:
            keep = messagebox.askyesno(
                "Transcription completed",
                "Save this transcript?\n\nYes = save to Kaalu\\Transcripts\n"
                "No = delete it", parent=self.root)
            if keep:
                self._save_transcript()
            else:
                self._clear_text()
                self.lines = []
                self._append_meta("Transcript deleted.")

    def _save_transcript(self):
        os.makedirs(TRANSCRIPT_DIR, exist_ok=True)
        stamp = (self.session_start or datetime.now()).strftime(
            "%Y-%m-%d_%H-%M-%S")
        path = os.path.join(TRANSCRIPT_DIR, "call_%s.txt" % stamp)
        with open(path, "w", encoding="utf-8") as f:
            f.write("Kaalu call transcript — %s\n" % stamp)
            f.write("=" * 50 + "\n\n")
            for ts, label, text, tr_lang, tr_text in self.lines:
                t = datetime.fromtimestamp(ts).strftime("%H:%M:%S")
                f.write("[%s] %s: %s\n" % (t, label, text))
                if tr_text:
                    f.write("        (%s) %s\n" % (tr_lang, tr_text))
        self._append_meta("Saved: %s" % path)
        messagebox.showinfo("Kaalu", "Transcript saved:\n%s" % path,
                            parent=self.root)

    def on_close(self):
        if self.running:
            if not messagebox.askokcancel(
                    "Kaalu", "Transcription is running. Stop and close?",
                    parent=self.root):
                return
            self.stop_event.set()
            self.running = False
            if self.lines and messagebox.askyesno(
                    "Kaalu", "Save transcript before closing?",
                    parent=self.root):
                self._save_transcript()
        self.cfg["geometry"] = self.root.winfo_geometry()
        save_config(self.cfg)
        try:
            if self.pa:
                self.pa.terminate()
        except Exception:
            pass
        self.root.destroy()

    def submit_segment(self, label, ts, pcm, rate, channels):
        bio = io.BytesIO()
        with wave.open(bio, "wb") as wf:
            wf.setnchannels(channels)
            wf.setsampwidth(2)
            wf.setframerate(rate)
            wf.writeframes(pcm)
        with self.pending_lock:
            self.pending += 1
        self.work_q.put((ts, label, bio.getvalue()))

    def _stt_worker(self):
        while True:
            try:
                ts, label, wav = self.work_q.get(timeout=0.4)
            except queue.Empty:
                if self.stop_event.is_set():
                    return
                continue
            try:
                text = self._transcribe(wav)
                tr_lang, tr_text = "", ""
                lang = self.target_lang
                if text and lang and not lang.startswith("None"):
                    tr_lang = lang
                    tr_text = self._translate(text, lang)
                if text:
                    self.ui_q.put(("line", ts, label, text, tr_lang, tr_text))
            finally:
                with self.pending_lock:
                    self.pending -= 1

    def _transcribe(self, wav_bytes):
        url = self.cfg["base_url"].rstrip("/") + "/audio/transcriptions"
        headers = {"Authorization": "Bearer " + self.cfg["api_key"]}
        models = [self.stt_model]
        fb = self.cfg.get("stt_fallback_model")
        if fb and fb not in models:
            models.append(fb)
        for model in models:
            try:
                r = requests.post(
                    url, headers=headers, timeout=40,
                    files={"file": ("seg.wav", wav_bytes, "audio/wav")},
                    data={"model": model})
            except Exception as e:
                self.ui_q.put(("status", "Network error: %s" % e))
                return ""
            if r.status_code == 200:
                self.stt_model = model
                try:
                    return (r.json().get("text") or "").strip()
                except Exception:
                    return ""
            if r.status_code in (400, 403, 404) and model != models[-1]:
                continue
            self.ui_q.put(("status", "STT %s: %s" % (r.status_code,
                                                     r.text[:100])))
            return ""
        return ""

    def _translate(self, text, target):
        url = self.cfg["base_url"].rstrip("/") + "/chat/completions"
        headers = {"Authorization": "Bearer " + self.cfg["api_key"]}
        body = {"model": self.cfg["chat_model"],
                "temperature": 0.2,
                "messages": [
                    {"role": "system",
                     "content": "Translate the user's message into %s. "
                                "Output only the translation." % target},
                    {"role": "user", "content": text}]}
        try:
            r = requests.post(url, headers=headers, json=body, timeout=40)
            if r.status_code == 200:
                return r.json()["choices"][0]["message"]["content"].strip()
            self.ui_q.put(("status", "Translate %s" % r.status_code))
        except Exception as e:
            self.ui_q.put(("status", "Translate failed: %s" % e))
        return ""

    def _poll(self):
        self._drain_ui()
        self.root.after(120, self._poll)

    def _drain_ui(self):
        while True:
            try:
                item = self.ui_q.get_nowait()
            except queue.Empty:
                break
            if item[0] == "line":
                _, ts, label, text, tr_lang, tr_text = item
                self.lines.append((ts, label, text, tr_lang, tr_text))
                t = datetime.fromtimestamp(ts).strftime("%H:%M:%S")
                tag = "me" if label == "Me" else "them"
                self._append("[%s] %s: " % (t, label), tag)
                self._append(text + "\n", "plain")
                if tr_text:
                    self._append("    > (%s) %s\n" % (tr_lang, tr_text), "tr")
            elif item[0] == "status":
                self.status_var.set(str(item[1])[:90])

    def _append(self, s, tag):
        self.text.configure(state="normal")
        self.text.insert("end", s, tag)
        self.text.see("end")
        self.text.configure(state="disabled")

    def _append_meta(self, s):
        self._append(s + "\n", "meta")

    def _clear_text(self):
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.configure(state="disabled")

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.root.mainloop()


if __name__ == "__main__":
    os.makedirs(KAALU_DIR, exist_ok=True)
    app = TranscriberApp()
    app.run()
