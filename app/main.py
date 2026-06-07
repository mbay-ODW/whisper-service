import os
import uuid
import json
import time
import threading
import subprocess
import tempfile
import shutil
from pathlib import Path
from datetime import datetime
from collections import OrderedDict

from flask import Flask, request, jsonify, render_template, abort, send_file, Response
from werkzeug.utils import secure_filename

app = Flask(__name__, template_folder="../templates")

AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "large-v3")
TRANSCRIPTS_DIR = Path("/transcripts")
MODEL_CACHE_DIR = Path("/model_cache")
TRANSCRIPTS_DIR.mkdir(exist_ok=True)

ALLOWED_EXTENSIONS = {"m4a", "mp3", "wav", "ogg", "flac", "webm", "mp4"}

# Job store: id -> dict
jobs = OrderedDict()
jobs_lock = threading.Lock()

# Worker queue
import queue
job_queue = queue.Queue()

DEFAULT_PROMPT = (
    "Elektroinstallation Holzständerbau: Gefach, Ständer, Fertigwand, "
    "Fertigfußboden FFB, Laibung, NYM 3x1,5 mm², 5x1,5, 3x2,5, 4x1,5, "
    "Rollladen, Schalterdose, Steckdose, Spiegelschrank, Heizkreisverteiler, "
    "Stellantrieb, Pendellüfter, Empore, HWR, Zentimeter, Meter"
)


def check_auth(req):
    if not AUTH_TOKEN:
        return True
    token = req.headers.get("Authorization", "")
    if token.startswith("Bearer "):
        token = token[7:]
    if token == AUTH_TOKEN:
        return True
    # Also check query param for UI convenience
    if req.args.get("token") == AUTH_TOKEN:
        return True
    return False


def get_whisper_model():
    """Load faster-whisper model with GPU/CPU detection."""
    from faster_whisper import WhisperModel

    use_cuda = False
    try:
        import torch
        use_cuda = torch.cuda.is_available()
    except ImportError:
        pass

    if use_cuda:
        model = WhisperModel(
            WHISPER_MODEL,
            device="cuda",
            compute_type="float16",
            download_root=str(MODEL_CACHE_DIR),
        )
    else:
        cpu_threads = max(4, os.cpu_count() or 4)
        model = WhisperModel(
            WHISPER_MODEL,
            device="cpu",
            compute_type="int8",
            cpu_threads=cpu_threads,
            download_root=str(MODEL_CACHE_DIR),
        )
    return model


# Load model once at startup in background
_model = None
_model_lock = threading.Lock()
_model_loading = False
_model_error = None


def load_model_background():
    global _model, _model_loading, _model_error
    _model_loading = True
    try:
        _model = get_whisper_model()
        print(f"Model {WHISPER_MODEL} loaded successfully.", flush=True)
    except Exception as e:
        _model_error = str(e)
        print(f"Failed to load model: {e}", flush=True)
    finally:
        _model_loading = False


threading.Thread(target=load_model_background, daemon=True).start()


def convert_to_wav(input_path: str, output_path: str):
    """Convert audio to 16kHz mono WAV using ffmpeg."""
    result = subprocess.run(
        [
            "ffmpeg", "-y", "-i", input_path,
            "-ar", "16000", "-ac", "1", "-f", "wav",
            output_path,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg error: {result.stderr}")


def transcribe_job(job_id: str):
    global _model

    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return
        job["status"] = "processing"
        job["progress"] = 0

    tmp_dir = None
    try:
        # Wait for model if still loading
        wait_start = time.time()
        while _model is None and _model_loading:
            if time.time() - wait_start > 300:
                raise RuntimeError("Model load timeout")
            time.sleep(2)

        if _model is None:
            raise RuntimeError(_model_error or "Model not available")

        with jobs_lock:
            job = jobs[job_id]
            if job.get("cancelled"):
                job["status"] = "cancelled"
                return

        tmp_dir = tempfile.mkdtemp()
        wav_path = os.path.join(tmp_dir, "audio.wav")

        with jobs_lock:
            job = jobs[job_id]

        convert_to_wav(job["file_path"], wav_path)

        with jobs_lock:
            job = jobs[job_id]
            if job.get("cancelled"):
                job["status"] = "cancelled"
                return
            job["progress"] = 10

        initial_prompt = job.get("initial_prompt", DEFAULT_PROMPT)
        model_name = job.get("model", WHISPER_MODEL)

        # Reload model if different model requested
        current_model = _model
        if model_name != WHISPER_MODEL:
            from faster_whisper import WhisperModel
            use_cuda = False
            try:
                import torch
                use_cuda = torch.cuda.is_available()
            except ImportError:
                pass
            if use_cuda:
                current_model = WhisperModel(
                    model_name, device="cuda", compute_type="float16",
                    download_root=str(MODEL_CACHE_DIR)
                )
            else:
                current_model = WhisperModel(
                    model_name, device="cpu", compute_type="int8",
                    cpu_threads=max(4, os.cpu_count() or 4),
                    download_root=str(MODEL_CACHE_DIR)
                )

        segments_gen, info = current_model.transcribe(
            wav_path,
            language="de",
            vad_filter=True,
            initial_prompt=initial_prompt,
            word_timestamps=False,
        )

        segments = []
        full_text_parts = []
        duration = info.duration if info.duration else 1

        for seg in segments_gen:
            with jobs_lock:
                if jobs[job_id].get("cancelled"):
                    jobs[job_id]["status"] = "cancelled"
                    return
                progress = min(90, int(10 + (seg.end / duration) * 80))
                jobs[job_id]["progress"] = progress

            segment_data = {
                "id": seg.id,
                "start": round(seg.start, 2),
                "end": round(seg.end, 2),
                "text": seg.text.strip(),
            }
            segments.append(segment_data)
            full_text_parts.append(seg.text.strip())

        full_text = " ".join(full_text_parts)

        # Save transcript
        date_str = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        original_name = Path(job["original_filename"]).stem
        txt_filename = f"{date_str}_{original_name}.txt"
        txt_path = TRANSCRIPTS_DIR / txt_filename
        txt_path.write_text(full_text, encoding="utf-8")

        with jobs_lock:
            jobs[job_id]["status"] = "done"
            jobs[job_id]["progress"] = 100
            jobs[job_id]["segments"] = segments
            jobs[job_id]["full_text"] = full_text
            jobs[job_id]["transcript_file"] = str(txt_path)
            jobs[job_id]["duration"] = round(info.duration, 1) if info.duration else 0
            jobs[job_id]["language"] = info.language
            jobs[job_id]["finished_at"] = time.time()

    except Exception as e:
        with jobs_lock:
            if job_id in jobs:
                jobs[job_id]["status"] = "error"
                jobs[job_id]["error"] = str(e)
    finally:
        if tmp_dir and os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)
        # Clean up uploaded file
        with jobs_lock:
            job = jobs.get(job_id, {})
        file_path = job.get("file_path", "")
        if file_path and os.path.exists(file_path):
            try:
                os.remove(file_path)
            except Exception:
                pass


def worker():
    while True:
        job_id = job_queue.get()
        try:
            transcribe_job(job_id)
        except Exception as e:
            print(f"Worker error for job {job_id}: {e}", flush=True)
        finally:
            job_queue.task_done()


# Start worker threads
NUM_WORKERS = 1  # Sequential to avoid VRAM issues
for _ in range(NUM_WORKERS):
    threading.Thread(target=worker, daemon=True).start()


# ── Routes ──────────────────────────────────────────────────────────────────

@app.before_request
def require_auth():
    if request.path in ("/health",):
        return
    if not check_auth(request):
        abort(401)


@app.route("/")
def index():
    return render_template("index.html", default_prompt=DEFAULT_PROMPT, current_model=WHISPER_MODEL)


@app.route("/health")
def health():
    return jsonify({"status": "ok", "model": WHISPER_MODEL, "model_ready": _model is not None})


@app.route("/api/model-status")
def model_status():
    return jsonify({
        "ready": _model is not None,
        "loading": _model_loading,
        "error": _model_error,
        "model": WHISPER_MODEL,
    })


@app.route("/api/upload", methods=["POST"])
def upload():
    files = request.files.getlist("files")
    if not files:
        return jsonify({"error": "No files provided"}), 400

    initial_prompt = request.form.get("initial_prompt", DEFAULT_PROMPT)
    model_name = request.form.get("model", WHISPER_MODEL)

    created_jobs = []
    upload_dir = Path(tempfile.mkdtemp(prefix="whisper_upload_"))

    for f in files:
        if not f.filename:
            continue
        ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
        if ext not in ALLOWED_EXTENSIONS:
            continue

        job_id = str(uuid.uuid4())
        safe_name = secure_filename(f.filename)
        dest = upload_dir / f"{job_id}_{safe_name}"
        f.save(str(dest))

        job = {
            "id": job_id,
            "status": "queued",
            "progress": 0,
            "original_filename": f.filename,
            "file_path": str(dest),
            "initial_prompt": initial_prompt,
            "model": model_name,
            "created_at": time.time(),
            "segments": [],
            "full_text": "",
            "error": None,
            "cancelled": False,
        }

        with jobs_lock:
            jobs[job_id] = job

        job_queue.put(job_id)
        created_jobs.append({"id": job_id, "filename": f.filename})

    if not created_jobs:
        return jsonify({"error": "No valid files (allowed: m4a, mp3, wav, ogg, flac, webm)"}), 400

    return jsonify({"jobs": created_jobs}), 202


@app.route("/api/jobs")
def list_jobs():
    with jobs_lock:
        result = []
        for job in reversed(list(jobs.values())):
            result.append({
                "id": job["id"],
                "status": job["status"],
                "progress": job["progress"],
                "filename": job["original_filename"],
                "model": job.get("model", WHISPER_MODEL),
                "created_at": job["created_at"],
                "finished_at": job.get("finished_at"),
                "error": job.get("error"),
                "duration": job.get("duration"),
            })
    return jsonify(result)


@app.route("/api/jobs/<job_id>")
def get_job(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "Not found"}), 404
    return jsonify({
        "id": job["id"],
        "status": job["status"],
        "progress": job["progress"],
        "filename": job["original_filename"],
        "model": job.get("model", WHISPER_MODEL),
        "created_at": job["created_at"],
        "finished_at": job.get("finished_at"),
        "error": job.get("error"),
        "segments": job.get("segments", []),
        "full_text": job.get("full_text", ""),
        "duration": job.get("duration"),
        "language": job.get("language"),
    })


@app.route("/api/jobs/<job_id>/cancel", methods=["POST"])
def cancel_job(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return jsonify({"error": "Not found"}), 404
        if job["status"] in ("done", "error", "cancelled"):
            return jsonify({"error": "Cannot cancel finished job"}), 400
        job["cancelled"] = True
        job["status"] = "cancelling"
    return jsonify({"ok": True})


@app.route("/api/jobs/<job_id>/retry", methods=["POST"])
def retry_job(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return jsonify({"error": "Not found"}), 404
        if job["status"] not in ("error", "cancelled"):
            return jsonify({"error": "Only failed/cancelled jobs can be retried"}), 400

        # Re-upload needed since file was deleted — just reset state if file exists
        # For retry, user should re-upload; this requeues with existing data if file present
        original_path = job.get("file_path", "")
        if not original_path or not os.path.exists(original_path):
            return jsonify({"error": "Original file no longer available, please re-upload"}), 400

        job["status"] = "queued"
        job["progress"] = 0
        job["error"] = None
        job["cancelled"] = False
        job["segments"] = []
        job["full_text"] = ""

    job_queue.put(job_id)
    return jsonify({"ok": True})


@app.route("/api/jobs/<job_id>/delete", methods=["DELETE"])
def delete_job(job_id):
    with jobs_lock:
        job = jobs.pop(job_id, None)
    if not job:
        return jsonify({"error": "Not found"}), 404
    return jsonify({"ok": True})


@app.route("/api/transcribe", methods=["POST"])
def api_transcribe():
    """Synchronous-style API: submit and get job ID back for polling."""
    f = request.files.get("file")
    if not f:
        return jsonify({"error": "No file provided"}), 400

    initial_prompt = request.form.get("initial_prompt", DEFAULT_PROMPT)
    model_name = request.form.get("model", WHISPER_MODEL)

    ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
    if ext not in ALLOWED_EXTENSIONS:
        return jsonify({"error": "Unsupported file type"}), 400

    job_id = str(uuid.uuid4())
    upload_dir = Path(tempfile.mkdtemp(prefix="whisper_upload_"))
    safe_name = secure_filename(f.filename)
    dest = upload_dir / f"{job_id}_{safe_name}"
    f.save(str(dest))

    job = {
        "id": job_id,
        "status": "queued",
        "progress": 0,
        "original_filename": f.filename,
        "file_path": str(dest),
        "initial_prompt": initial_prompt,
        "model": model_name,
        "created_at": time.time(),
        "segments": [],
        "full_text": "",
        "error": None,
        "cancelled": False,
    }

    with jobs_lock:
        jobs[job_id] = job

    job_queue.put(job_id)
    return jsonify({"job_id": job_id, "status": "queued"}), 202


@app.route("/api/download/<job_id>/<fmt>")
def download_result(job_id, fmt):
    with jobs_lock:
        job = jobs.get(job_id)
    if not job or job["status"] != "done":
        return jsonify({"error": "Not ready"}), 404

    segments = job.get("segments", [])
    full_text = job.get("full_text", "")
    base_name = Path(job["original_filename"]).stem

    if fmt == "txt":
        return Response(
            full_text,
            mimetype="text/plain",
            headers={"Content-Disposition": f'attachment; filename="{base_name}.txt"'},
        )
    elif fmt == "json":
        data = json.dumps({"segments": segments, "full_text": full_text}, ensure_ascii=False, indent=2)
        return Response(
            data,
            mimetype="application/json",
            headers={"Content-Disposition": f'attachment; filename="{base_name}.json"'},
        )
    elif fmt == "srt":
        srt_lines = []
        for i, seg in enumerate(segments, 1):
            start = _seconds_to_srt(seg["start"])
            end = _seconds_to_srt(seg["end"])
            srt_lines.append(f"{i}\n{start} --> {end}\n{seg['text']}\n")
        srt_content = "\n".join(srt_lines)
        return Response(
            srt_content,
            mimetype="text/plain",
            headers={"Content-Disposition": f'attachment; filename="{base_name}.srt"'},
        )
    else:
        return jsonify({"error": "Unknown format"}), 400


def _seconds_to_srt(seconds: float) -> str:
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)
