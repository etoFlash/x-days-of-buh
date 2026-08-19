#!/usr/bin/env python3
"""main.py — сквозной демо-прогон модуля 01 учебного банка Mini Bank.

Сценарий одного операционного дня (2026-01-07, открыт seed'ом):
  1) Иванова вносит 100 000 RUB наличными на текущий счёт;
  2) Иванова покупает 1 000 USD: банк продаёт валюту по 92.50
     при учётном курсе дня 92.40 — 10 RUB курсовой разницы (доход банка);
  3) перевод 5 000 RUB Иванова → Сидорова (клиент–клиент);
  4) выдача кредита 300 000 RUB Сидоровой на текущий счёт;
  5) комиссия 250 RUB за перевод (доход банка);
  6) закрытие операционного дня;
  7) пробный баланс.

Запуск из корня репозитория:
    python -m src.main
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import psycopg

from src import accounts as acc
from src.db import connect, ensure_schema, ensure_seed
from src.ledger import (
    EntryLine,
    close_operating_day,
    post_entry,
    print_trial_balance,
    trial_balance,
)

OPERATING_DAY = date(2026, 1, 7)

USD_AMOUNT = Decimal("1000.00")
USD_RATE_BOOK = Decimal("92.40")   # учётный курс дня (fx_rates)
USD_RATE_DEAL = Decimal("92.50")   # курс продажи клиенту
USD_BOOK_VALUE = USD_AMOUNT * USD_RATE_BOOK   # 92 400.00
USD_DEAL_VALUE = USD_AMOUNT * USD_RATE_DEAL   # 92 500.00
USD_DEAL_DIFF = USD_DEAL_VALUE - USD_BOOK_VALUE  # 100.00 — курсовая разница банка

# Лицевые счета доходов, которые seed не заводит заранее
INCOME_ACCOUNTS = [
    ("70601.810.00000000001", "70601"),  # процентные доходы по кредитам
    ("70606.810.00000000001", "70606"),  # процентные расходы по вкладам
    ("70611.810.00000000001", "70611"),  # комиссионные доходы
    ("70613.810.00000000001", "70613"),  # доходы от переоценки валюты
    ("70614.810.00000000001", "70614"),  # расходы от переоценки валюты
]


def ensure_income_accounts(conn: psycopg.Connection) -> None:
    """Заводит лицевые счета доходов/расходов (по символам, без клиента)."""
    with conn.cursor() as cur:
        for number, coa in INCOME_ACCOUNTS:
            cur.execute(
                """
                INSERT INTO personal_accounts
                    (account_number, coa_number, customer_id,
                     product_code, currency, opened_on)
                VALUES (%s, %s, NULL, NULL, 'RUB', %s)
                ON CONFLICT (account_number) DO NOTHING
                """,
                (number, coa, OPERATING_DAY),
            )


def run_demo() -> None:
    with connect() as conn:
        with conn.transaction():
            applied = ensure_schema(conn)
            seeded = ensure_seed(conn)
            ensure_income_accounts(conn)
            if applied:
                print(f"Миграции применены: {', '.join(applied)}")
            if seeded:
                print(f"Seed загружен: {', '.join(seeded)}")

        # 1) Взнос наличных: деньги пришли в кассу (актив растёт),
        #    банк должен клиенту (пассив растёт).
        with conn.transaction():
            post_entry(
                conn, OPERATING_DAY,
                "Взнос наличных Ивановой на текущий счёт",
                [
                    EntryLine(acc.CASH_RUB, Decimal("100000.00"), "debit"),
                    EntryLine(acc.IVANOVA_RUB, Decimal("100000.00"), "credit"),
                ],
                doc_type="cash_in",
            )
            print("1) Дт 20202 Касса — Кт 40817 Счёт Ивановой, 100 000.00: взнос наличных")

        # 2) Конверсия: Иванова покупает 1 000 USD за рубли.
        #    Банк продаёт валюту по курсу сделки 92.50, учётный курс — 92.40.
        #    Дт 40817 — Кт 47423 по курсу сделки (92 500),
        #    Дт 47423 — Кт 40820(USD) по учётному курсу (92 400),
        #    разница 100 — доход банка на счёте 70613.
        with conn.transaction():
            post_entry(
                conn, OPERATING_DAY,
                "Продажа 1 000 USD Ивановой из кассы: курс сделки 92.50, учётный 92.40",
                [
                    EntryLine(acc.IVANOVA_RUB, USD_DEAL_VALUE, "debit"),
                    EntryLine(acc.FX_CONVERSION, USD_DEAL_VALUE, "credit"),
                    EntryLine(acc.FX_CONVERSION, USD_BOOK_VALUE, "debit"),
                    EntryLine(acc.IVANOVA_USD, USD_BOOK_VALUE, "credit",
                              amount_currency=USD_AMOUNT),
                    EntryLine(acc.FX_CONVERSION, USD_DEAL_DIFF, "debit"),
                    EntryLine(acc.FX_INCOME, USD_DEAL_DIFF, "credit"),
                    EntryLine(acc.FX_CONVERSION, USD_BOOK_VALUE, "debit"),
                    EntryLine(acc.CASH_USD, USD_BOOK_VALUE, "credit",
                              amount_currency=USD_AMOUNT),
                ],
                doc_type="fx_deal", external_ref="FX-0001",
            )
            print("2) Конверсия: Дт 40817(RUB) 92 500 — Кт 47423; "
                  "Дт 47423 — Кт 40820(USD) 92 400; "
                  "Дт 47423 — Кт 20206(USD) 92 400 (выдача из кассы); "
                  "Дт 47423 — Кт 70613 100.00 (курсовая разница).\n"
                  "   Примечание: счёт 47423 по этой сделке сомкнулся в ноль "
                  "(92 500 по Дт и по Кт) — так и должно быть у техсчёта.")

        # 3) Перевод клиент–клиент: пассив перед одним клиентом становится
        #    пассивом перед другим. Активы банка не меняются.
        with conn.transaction():
            post_entry(
                conn, OPERATING_DAY,
                "Перевод 5 000 RUB Иванова → Сидорова",
                [
                    EntryLine(acc.IVANOVA_RUB, Decimal("5000.00"), "debit"),
                    EntryLine(acc.SIDOROVA_RUB, Decimal("5000.00"), "credit"),
                ],
                doc_type="payment",
            )
            print("3) Дт 40817 Иванова — Кт 40817 Сидорова, 5 000.00: перевод клиент–клиент")

        # 4) Выдача кредита: у банка появляется требование к заёмщику (актив),
        #    у клиента — деньги на счёте (пассив банка).
        with conn.transaction():
            post_entry(
                conn, OPERATING_DAY,
                "Выдача потребительского кредита Сидоровой",
                [
                    EntryLine(acc.SIDOROVA_LOAN, Decimal("300000.00"), "debit"),
                    EntryLine(acc.SIDOROVA_RUB, Decimal("300000.00"), "credit"),
                ],
                doc_type="loan_issue",
            )
            print("4) Дт 45205 Кредит Сидоровой — Кт 40817 Сидорова, 300 000.00: выдача кредита")

        # 5) Комиссия банка: деньги списываются со счёта клиента
        #    и становятся доходом банка.
        with conn.transaction():
            post_entry(
                conn, OPERATING_DAY,
                "Комиссия за перевод с Ивановой",
                [
                    EntryLine(acc.IVANOVA_RUB, Decimal("250.00"), "debit"),
                    EntryLine(acc.FEE_INCOME, Decimal("250.00"), "credit"),
                ],
                doc_type="fee",
            )
            print("5) Дт 40817 Иванова — Кт 70611 Комиссионные доходы, 250.00: комиссия")

        # 6) Закрытие операционного дня с контролем сбалансированности журнала.
        with conn.transaction():
            close_operating_day(conn, OPERATING_DAY, closed_by="src.main")
            print(f"6) Операционный день {OPERATING_DAY} закрыт")

        # 7) Отчёт.
        rows = trial_balance(conn, OPERATING_DAY)
        print_trial_balance(rows, OPERATING_DAY)


if __name__ == "__main__":
    run_demo()
