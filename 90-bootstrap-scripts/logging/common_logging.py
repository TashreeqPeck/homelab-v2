from datetime import datetime
import pathlib


def log(message: str, level: str = "INFO", script_name: str | None = None) -> None:
    name = script_name or pathlib.Path(__file__).name
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [{level}] [{name}] {message}")