"""Подключение к PostgreSQL и применение миграций/seed-данных."""

from __future__ import annotations

import os
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote_plus

import psycopg

REPO_ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = REPO_ROOT / "db" / "migrations"
SEEDS_DIR = REPO_ROOT / "db" / "seeds"

# Параметры подключения по умолчанию (переопределяются переменными окружения).
# Для docker-compose.yml из корня репозитория хватит значений по умолчанию.
DEFAULT_HOST = os.environ.get("MINIBANK_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.environ.get("MINIBANK_PORT", "5432"))
DEFAULT_DB = os.environ.get("MINIBANK_DB", "minibank")
DEFAULT_USER = os.environ.get("MINIBANK_USER", "minibank")
DEFAULT_PASSWORD = os.environ.get("MINIBANK_PASSWORD", "minibank")


def get_dsn() -> str:
    """DSN: либо MINIBANK_DSN целиком, либо собираем из MINIBANK_* частей."""
    dsn = os.environ.get("MINIBANK_DSN")
    if dsn:
        return dsn
    return (
        f"postgresql://{quote_plus(DEFAULT_USER)}:{quote_plus(DEFAULT_PASSWORD)}"
        f"@{DEFAULT_HOST}:{DEFAULT_PORT}/{DEFAULT_DB}"
    )


@contextmanager
def connect(dsn: str | None = None):
    """Контекстный менеджер соединения.

    По умолчанию autocommit выключен: вызывающий код управляет транзакцией
    (conn.commit() / conn.rollback()) — как платёжный движок в банке.
    """
    conn = psycopg.connect(dsn or get_dsn())
    try:
        yield conn
    finally:
        conn.close()


def _apply_sql_file(conn: psycopg.Connection, path: Path) -> None:
    with conn.cursor() as cur:
        cur.execute(path.read_text(encoding="utf-8"))


def ensure_schema(conn: psycopg.Connection) -> list[str]:
    """Применяет все миграции из db/migrations (идемпотентны)."""
    applied: list[str] = []
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        _apply_sql_file(conn, path)
        applied.append(path.name)
    return applied


def ensure_seed(conn: psycopg.Connection) -> list[str]:
    """Загружает seed-данные, если план счетов ещё пуст (идемпотентны)."""
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM chart_of_accounts")
        (count,) = cur.fetchone()
    if count:
        return []
    applied: list[str] = []
    for path in sorted(SEEDS_DIR.glob("*.sql")):
        _apply_sql_file(conn, path)
        applied.append(path.name)
    return applied
