"""iHypnusCare for Windows: pywebview front end for hypnus_report.py.

Welcome screen -> pick a card (or pass it as the first argument / drop it on the .exe) -> progress
while the reader runs in-process -> report shown in the same window, with PDF export via a Save dialog.
Built into a single .exe by .github/workflows/windows.yml (PyInstaller). Also runs on macOS/Linux
for development: `pip install pywebview` then `python tools/win/ihypnuscare_win.py [card]`.
"""
import base64
import json
import os
import sys
import threading
import time
import traceback

import webview

if getattr(sys, "frozen", False):           # PyInstaller one-file: everything unpacked into _MEIPASS
    BASE = sys._MEIPASS
    UI = os.path.join(BASE, "ui.html")
else:                                       # source checkout: tools/win/ next to tools/hypnus_report.py
    WIN = os.path.dirname(os.path.abspath(__file__))
    BASE = os.path.dirname(WIN)
    UI = os.path.join(WIN, "ui.html")
sys.path.insert(0, BASE)
import hypnus_report as reader  # noqa: E402

VERSION = "1.10"
DATA_DIR = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.local/share"), "iHypnusCare")
SETTINGS = os.path.join(DATA_DIR, "settings.json")
FOLDER_DIALOG = getattr(getattr(webview, "FileDialog", None), "FOLDER", None) or webview.FOLDER_DIALOG
SAVE_DIALOG = getattr(getattr(webview, "FileDialog", None), "SAVE", None) or webview.SAVE_DIALOG


def load_settings():
    try:
        with open(SETTINGS, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_settings(s):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(SETTINGS, "w", encoding="utf-8") as fh:
        json.dump(s, fh)


class Api:
    """Methods callable from the pages as window.pywebview.api.<name>()."""

    def __init__(self):
        self._window = None
        self._busy = False
        self._cancelled = False

    def info(self):
        logo = os.path.join(BASE, "assets", "hypnus-logo.png")
        with open(logo, "rb") as fh:
            data = "data:image/png;base64," + base64.b64encode(fh.read()).decode()
        last = load_settings().get("last_folder")
        return {"logo": data, "version": VERSION,
                "last": last if last and os.path.isdir(last) else None}

    def choose_folder(self):
        if self._busy:
            return
        start = load_settings().get("last_folder") or ""
        picked = self._window.create_file_dialog(FOLDER_DIALOG, directory=os.path.dirname(start) if start else "")
        if picked:
            self.read_card(picked[0] if isinstance(picked, (list, tuple)) else picked)

    def open_last(self):
        last = load_settings().get("last_folder")
        if last:
            self.read_card(last)

    def cancel(self):
        self._cancelled = True

    def read_card(self, folder):
        if self._busy:
            return
        self._busy = True
        self._cancelled = False
        threading.Thread(target=self._read, args=(folder,), daemon=True).start()

    def _read(self, folder):
        js = self._window.evaluate_js
        try:
            if os.path.basename(self._window.get_current_url() or "").lower() != "ui.html":
                self._window.load_url(UI)
                time.sleep(0.8)
            js(f"showLoading({json.dumps(folder.replace(os.path.expanduser('~'), '~', 1))})")
            last = [0.0]

            def progress(done, total, name, files):
                if self._cancelled:
                    raise KeyboardInterrupt
                now = time.time()
                if done == total or now - last[0] > 0.08:     # don't flood the bridge
                    last[0] = now
                    js(f"progress({done}, {total}, {json.dumps(name)}, {files})")

            root = reader.find_root(folder)
            out = os.path.join(DATA_DIR, "report.html")
            os.makedirs(DATA_DIR, exist_ok=True)
            reader.write_html(root, out, progress=progress)
            s = load_settings()
            s["last_folder"] = folder
            save_settings(s)
            self._window.set_title(f"iHypnusCare - {os.path.basename(os.path.normpath(folder))}")
            self._window.load_url(out)
        except KeyboardInterrupt:
            js("showWelcome()")
        except SystemExit as e:          # find_root / write_html report problems this way
            js(f"showError({json.dumps(str(e))})")
        except Exception as e:           # noqa: BLE001 - show anything unexpected instead of hanging
            traceback.print_exc()
            js(f"showError({json.dumps(f'{type(e).__name__}: {e}')})")
        finally:
            self._busy = False

    def save_pdf(self, name, data):
        """Called by the report's Export PDF button with the PDF as base64."""
        docs = os.path.join(os.path.expanduser("~"), "Documents")
        path = self._window.create_file_dialog(SAVE_DIALOG, directory=docs if os.path.isdir(docs) else "",
                                              save_filename=name, file_types=("PDF files (*.pdf)",))
        if not path:
            return ""
        path = path[0] if isinstance(path, (list, tuple)) else path
        if not path.lower().endswith(".pdf"):
            path += ".pdf"
        with open(path, "wb") as fh:
            fh.write(base64.b64decode(data))
        if sys.platform == "win32":
            os.startfile(os.path.dirname(path))  # noqa: S606 - show the saved file's folder
        return f"Saved {os.path.basename(path)}"


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    if getattr(sys, "frozen", False):
        # a --windowed exe has no console: keep errors (ours and pywebview's) in a log file
        sys.stdout = sys.stderr = open(os.path.join(DATA_DIR, "log.txt"), "w", encoding="utf-8", buffering=1)
    print(f"iHypnusCare {VERSION} {time.strftime('%Y-%m-%d %H:%M:%S')} pywebview {getattr(webview, '__version__', '?')} args {sys.argv[1:]}")
    api = Api()
    window = webview.create_window("iHypnusCare", UI, js_api=api, width=1180, height=820,
                                   min_size=(860, 620), background_color="#F9F9F7")
    api._window = window
    card = sys.argv[1] if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else None

    def started():
        try:
            if card:
                window.events.loaded.wait(15)
                time.sleep(0.5)
                api.read_card(card)
        except Exception:  # noqa: BLE001
            traceback.print_exc()

    webview.start(started, private_mode=False, storage_path=os.path.join(DATA_DIR, "webview"))


if __name__ == "__main__":
    main()
