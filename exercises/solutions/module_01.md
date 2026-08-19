# Решения модуля 01

Не открывай, пока не решил сам. Эталон — «один из правильных», не единственный.

## Разминка

1. `Дт 40817 Сидорова — Кт 20202 Касса, 10 000,00`. 40817 — пассив
   (долг банка уменьшается), 20202 — актив (наличные уходят).
2. Перевод клиент–клиент — перестановка внутри пассива: долг одному
   клиенту стал долгом другому. Сумма пассивов не изменилась.
3. Нет, не всегда (в пути между днями — нормально), но **на конец
   операционного дня** несомкнутый техсчёт — повод для разбирательства:
   значит, какая-то часть цепочки проводок не дошла.

## Задача 1

```sql
BEGIN;
-- вариант А: переоткрыть день (учебно; в реальном банке — отдельная процедура)
UPDATE operating_days SET status='open', closed_at=NULL, closed_by=NULL
WHERE operating_day='2026-01-07';

WITH doc AS (
    INSERT INTO documents (operating_day, doc_type, description)
    VALUES ('2026-01-07','cash_in','Взнос наличных Петровым на вклад')
    RETURNING document_id
), je AS (
    INSERT INTO journal_entries (document_id, entry_date, description)
    SELECT document_id,'2026-01-07','Дт 20202 Касса — Кт 42301 Вклад Петрова'
    FROM doc RETURNING entry_id
)
INSERT INTO entry_lines (entry_id, account_id, debit_amount, credit_amount, line_no)
SELECT je.entry_id, pa.account_id,
       CASE WHEN pa.coa_number='20202' THEN 50000.00 END,
       CASE WHEN pa.coa_number='42301' THEN 50000.00 END,
       CASE WHEN pa.coa_number='20202' THEN 1 ELSE 2 END
FROM je CROSS JOIN personal_accounts pa
WHERE pa.account_number IN ('20202.810.00000000001','42301.810.00000000001');
COMMIT;
```

## Задача 2

```sql
WITH days(d) AS (VALUES (date '2026-01-06'), (date '2026-01-07'))
SELECT d.d AS as_of,
       GREATEST(SUM(COALESCE(el.credit_amount,0)-COALESCE(el.debit_amount,0)),0) AS balance_credit
FROM days d
CROSS JOIN personal_accounts pa
LEFT JOIN entry_lines el ON el.account_id = pa.account_id
LEFT JOIN journal_entries je ON je.entry_id = el.entry_id
                            AND je.status='posted' AND je.entry_date <= d.d
WHERE pa.account_number='40817.810.00000000001'
GROUP BY d.d ORDER BY d.d;
```

## Задача 3

См. `db/queries/account_card.sql` — окно `SUM(...) OVER (ORDER BY entry_date,
document_id ROWS UNBOUNDED PRECEDING)` поверх движений счёта.

## Задача 4

```sql
SELECT pa.coa_number,
       SUM(el.debit_amount)  AS turnover_debit,
       SUM(el.credit_amount) AS turnover_credit
FROM entry_lines el
JOIN journal_entries je ON je.entry_id=el.entry_id AND je.status='posted'
JOIN personal_accounts pa ON pa.account_id=el.account_id
WHERE je.entry_date='2026-01-07'
GROUP BY pa.coa_number
UNION ALL
SELECT 'ИТОГО', SUM(el.debit_amount), SUM(el.credit_amount)
FROM entry_lines el
JOIN journal_entries je ON je.entry_id=el.entry_id AND je.status='posted'
WHERE je.entry_date='2026-01-07'
ORDER BY 1;
```

## Задача 5

(а) — `db/queries/unbalanced_documents.sql`; (б):

```sql
SELECT * FROM entry_lines
WHERE (debit_amount IS NULL) = (credit_amount IS NULL);  -- обе или ни одной
```

(в):

```sql
SELECT d.* FROM documents d
LEFT JOIN journal_entries je ON je.document_id=d.document_id
WHERE je.entry_id IS NULL;
```

Возможности: (б) заблокирована CHECK'ом, (а) — констрейнт-триггером на
COMMIT, (в) допустима схемой как промежуточное состояние внутри транзакции,
но недопустима после COMMIT нашим кодом. Контроль (а) нужен всегда:
триггеры могут быть временно отключены при миграциях, а журнал может
наполняться обходными загрузками — сверка не доверяет механизму, она
доказывает результат.

## Задача 6

```python
post_entry(
    conn, OPERATING_DAY,
    "Частичное погашение кредита Сидоровой",
    [
        EntryLine(acc.SIDOROVA_RUB, Decimal("20000.00"), "debit"),
        EntryLine(acc.SIDOROVA_LOAN, Decimal("20000.00"), "credit"),
    ],
    doc_type="loan_repayment",
)
```

## Задача 7

Хранимые остатки нужны ради скорости: промышленная АБС обслуживает миллионы
запросов остатков в секунду, пересчёт из журнала неприемлем. Цена —
риск рассинхронизации «журнал vs остатки» и необходимость вести остатки
транзакционно с проводками. Обязательный контроль: ежедневная сверка
«хранимый остаток = пересчитанный из журнала» (reconciliation), расхождение
— инцидент с блокировкой закрытия дня.
