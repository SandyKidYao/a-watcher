"""Run with a path to Pi 1.5.2. Uses isolated directories and an in-process model."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[2]


def verify(pi, root, outcome):
    extensions = root / "agent/extensions"
    extensions.mkdir(parents=True)
    shutil.copy(REPO / "Resources/Pi/a-watcher.ts", extensions)
    shutil.copy(Path(__file__).with_name("fixture.ts"), extensions)
    (root / "home").mkdir()
    (root / "agent/settings.json").write_text(json.dumps({"retry": {"enabled": False}}))
    env = {"PATH": os.environ["PATH"], "HOME": str(root / "home"), "PI_OFFLINE": "1",
           "PI_CODING_AGENT_DIR": str(root / "agent"), "A_WATCHER_DATA_DIR": str(root / "data"),
           "AW_FIXTURE_OUTCOME": outcome}
    proc = subprocess.Popen([pi, "--mode", "rpc", "--provider", "fixture", "--model", "local", "--no-tools"],
                            env=env, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def send(record):
        proc.stdin.write(json.dumps(record) + "\n")
        proc.stdin.flush()

    def answer_dialog():
        for line in proc.stdout:
            event = json.loads(line)
            if event.get("type") == "extension_ui_request" and event.get("method") == "confirm":
                time.sleep(0.3)
                send({"type": "extension_ui_response", "id": event["id"], "confirmed": True})

    threading.Thread(target=answer_dialog, daemon=True).start()
    seen = []
    try:
        send({"type": "prompt", "message": "fixture"})
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and proc.poll() is None:
            for file in (root / "data/pi-status").glob("*.jsonl"):
                record = json.loads(file.read_text())
                assert set(record) == {"version", "root", "id", "pid", "time", "completions", "cwd", "status"}
                status = record["status"]
                if not seen or seen[-1] != status:
                    seen.append(status)
                    if status == "running" and outcome == "interrupted":
                        send({"type": "abort"})
                if status == outcome:
                    assert "waitingApproval" in seen and "running" in seen
                    assert len(record["completions"]) == (1 if outcome == "idle" else 0)
                    print("PASS", " → ".join(seen))
                    return
            time.sleep(0.025)
        raise AssertionError(f"Expected {outcome}, observed {seen}")
    finally:
        proc.terminate()
        proc.wait(timeout=5)


if __name__ == "__main__":
    pi = shutil.which(sys.argv[1] if len(sys.argv) > 1 else "pi")
    if not pi:
        sys.exit("Pass the executable path to Pi 1.5.2")
    with tempfile.TemporaryDirectory() as temp:
        for outcome in ("idle", "error", "interrupted"):
            verify(pi, Path(temp) / outcome, outcome)
