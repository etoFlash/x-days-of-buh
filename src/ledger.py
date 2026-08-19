"""ledger.py — операции над главной книгой Mini Bank.

Python здесь не «вторая главная книга в pandas»: он только создаёт документы
и проводки. Все инварианты (сумма Дт = сумме Кт, запрет проведения в закрытый
операционный день) контролирует PostgreSQL триггерами — см. db/migrations.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal

import psycopg


class LedgerError(Exception):
    """Ошибка прикладного уровня главной книги."""


@dataclass(frozen=True)
class EntryLine:
    """Одна сторона проводки по лицевому счёту."""

    account: str           # номер лицевого счёта, напр. '40817.810.00000000001'
    amount: Decimal        # сумма в функциональной валюте (RUB), > 0
    side: str = "debit"    # 'debit' или 'credit'
    amount_currency: Decimal | None = None  # валютная сумма для счетов в валюте


@dataclass(frozen=True)
class TrialBalanceRow:
    account_number: str
    account_name: str
    currency: str
    turnover_debit: Decimal
    turnover_credit: Decimal
    closing_debit: Decimal
    closing_credit: Decimal


def open_operating_day(conn: psycopg.Connection, day: date) -> None:
    """Открывает операционный день (если уже есть — оставляет как есть)."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO operating_days (operating_day, status)
            VALUES (%s, 'open')
            ON CONFLICT (operating_day) DO NOTHING
            """,
            (day,),
        )


def close_operating_day(conn: psycopg.Connection, day: date, closed_by: str = "python") -> None:
    """Закрывает операционный день после контроля сбалансированности журнала."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT count(*)
            FROM journal_entries je
            JOIN entry_lines el ON el.entry_id = je.entry_id
            WHERE je.entry_date = %s
            GROUP BY je.entry_id
            HAVING SUM(COALESCE(el.debit_amount, 0))
                <> SUM(COALESCE(el.credit_amount, 0))
            """,
            (day,),
        )
        bad = cur.fetchall()
        if bad:
            raise LedgerError(f"В дне {day} есть несбалансированные проводки: {bad}")
        cur.execute(
            """
            UPDATE operating_days
            SET status = 'closed', closed_at = now(), closed_by = %s
            WHERE operating_day = %s AND status = 'open'
            """,
            (closed_by, day),
        )
        if cur.rowcount == 0:
            raise LedgerError(f"Операционный день {day} не найден или уже закрыт")


def _account_exists(cur: psycopg.Cursor, account_number: str) -> None:
    cur.execute(
        "SELECT 1 FROM personal_accounts WHERE account_number = %s",
        (account_number,),
    )
    if cur.fetchone() is None:
        raise LedgerError(f"Лицевой счёт {account_number} не найден")


def post_entry(
    conn: psycopg.Connection,
    doc_date: date,
    description: str,
    lines: list[EntryLine],
    doc_type: str = "memo",
    external_ref: str | None = None,
) -> int:
    """Проводит документ двойной записью и возвращает entry_id.

    Валидация на уровне Python — только читаемость ошибок; гарантии даёт БД:
    триггер check_entry_balance (Дт = Кт на COMMIT) и check_operating_day_open.
    """
    if len(lines) < 2:
        raise LedgerError("Проводка должна содержать минимум две строки (Дт и Кт)")

    total_debit = sum(l.amount for l in lines if l.side == "debit")
    total_credit = sum(l.amount for l in lines if l.side == "credit")
    if total_debit != total_credit:
        raise LedgerError(
            f"Документ не сбалансирован: Дт {total_debit} != Кт {total_credit}"
        )

    with conn.cursor() as cur:
        for line in lines:
            _account_exists(cur, line.account)

        cur.execute(
            """
            INSERT INTO documents (operating_day, doc_type, description, external_ref)
            VALUES (%s, %s, %s, %s)
            RETURNING document_id
            """,
            (doc_date, doc_type, description, external_ref),
        )
        (document_id,) = cur.fetchone()

        cur.execute(
            """
            INSERT INTO journal_entries (document_id, entry_date, description)
            VALUES (%s, %s, %s)
            RETURNING entry_id
            """,
            (document_id, doc_date, description),
        )
        (entry_id,) = cur.fetchone()

        for line_no, line in enumerate(lines, start=1):
            cur.execute(
                """
                INSERT INTO entry_lines
                    (entry_id, account_id, debit_amount, credit_amount,
                     currency, amount_currency, line_no)
                SELECT %s, pa.account_id, %s, %s, pa.currency, %s, %s
                FROM personal_accounts pa
                WHERE pa.account_number = %s
                """,
                (
                    entry_id,
                    line.amount if line.side == "debit" else None,
                    line.amount if line.side == "credit" else None,
                    line.amount_currency,
                    line_no,
                    line.account,
                ),
            )

    return entry_id


def trial_balance(conn: psycopg.Connection, as_of: date) -> list[TrialBalanceRow]:
    """Пробный баланс на дату — данные берутся из SQL-функции trial_balance()."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT account_number, account_name, currency,
                   turnover_debit, turnover_credit, closing_debit, closing_credit
            FROM trial_balance(%s)
            WHERE turnover_debit <> 0 OR turnover_credit <> 0
               OR closing_debit <> 0 OR closing_credit <> 0
            ORDER BY account_number
            """,
            (as_of,),
        )
        return [
            TrialBalanceRow(
                account_number=r[0], account_name=r[1], currency=r[2],
                turnover_debit=r[3], turnover_credit=r[4],
                closing_debit=r[5], closing_credit=r[6],
            )
            for r in cur.fetchall()
        ]


def print_trial_balance(rows: list[TrialBalanceRow], as_of: date) -> None:
    """Печатает пробный баланс и итоговый контроль Дт = Кт."""
    header = (
        f"{'Лицевой счёт':<24} {'Название':<34} {'Вал':<3}"
        f" {'Оборот Дт':>14} {'Оборот Кт':>14}"
        f" {'Сальдо Дт':>14} {'Сальдо Кт':>14}"
    )
    print(f"\nПробный баланс Mini Bank на {as_of}")
    print(header)
    print("-" * len(header))
    for r in rows:
        print(
            f"{r.account_number:<24} {r.account_name:<34} {r.currency:<3}"
            f" {r.turnover_debit:>14,.2f} {r.turnover_credit:>14,.2f}"
            f" {r.closing_debit:>14,.2f} {r.closing_credit:>14,.2f}"
        )
    total_debit = sum(r.closing_debit for r in rows)
    total_credit = sum(r.closing_credit for r in rows)
    print("-" * len(header))
    print(f"{'ИТОГО':<62} {total_debit:>28,.2f} {total_credit:>14,.2f}")
    if total_debit != total_credit:
        raise LedgerError(
            f"Пробный баланс не сошёлся: Дт {total_debit} != Кт {total_credit}"
        )
    print("Контроль пройден: сумма дебетовых сальдо = сумме кредитовых сальдо.")
