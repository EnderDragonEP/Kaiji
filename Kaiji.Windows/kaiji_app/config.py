"""Paths and app settings. Settings are about this PC - how the app looks, and where it syncs
(config.json; the password is in Windows Credential Manager, see credentials.py); everything
about your money - entries, the plan, the currency - is in the database, so a backup has all of
it."""
import dataclasses
import json
import os

APP_NAME = "Kaiji"
APP_TITLE = "Kaiji 花錢"
APP_VERSION = "1.0"
APP_DIR = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), APP_NAME)
CONFIG_PATH = os.path.join(APP_DIR, "config.json")
DB_PATH = os.path.join(APP_DIR, "kaiji.db")
BACKUP_DIR = os.path.join(APP_DIR, "backups")
LOCK_PATH = os.path.join(APP_DIR, "kaiji.lock")


@dataclasses.dataclass
class Settings:
    week_start: int = 0               # first calendar column: 0 = Monday, 6 = Sunday
    theme: str = "system"             # "system", "light" or "dark"
    accent_color: str = ""            # "#rrggbb", or "" for the Windows accent color
    welcomed: bool = False            # the first-run setup was shown
    sync: bool = False                # sync through PostgreSQL (sync.py)
    sync_host: str = ""
    sync_port: int = 5432
    sync_database: str = "kaiji"
    sync_user: str = "kaiji"
    sync_tls: bool = True             # an encrypted connection

    @classmethod
    def load(cls):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                data = json.load(f)
        except (FileNotFoundError, ValueError):
            return cls()
        names = {f.name for f in dataclasses.fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in names})

    def save(self):
        os.makedirs(APP_DIR, exist_ok=True)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(dataclasses.asdict(self), f, ensure_ascii=False, indent=2)
        os.replace(tmp, CONFIG_PATH)
