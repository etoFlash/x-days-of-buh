-- ============================================================================
-- account_card.sql — карточка лицевого счёта за период
-- ============================================================================
-- Входящее сальдо → все проводки по счёту в хронологии → нарастающее сальдо
-- (оконная функция). Это то, что бухгалтер называет «карточкой счёта».
--
-- Запуск из psql:
--   psql ... -v acc='40817.810.00000000001' \
--            -v date_from='2026-01-05' -v date_to='2026-01-07' \
--            -f db/queries/account_card.sql
-- ============================================================================

-- Все движения по счёту до конца периода (нужны и для входящего сальдо,
-- и для нарастающего итога).
WITH scope AS (
    SELECT
        je.entry_date,
        d.document_id,
        d.doc_type,
        je.description,
        el.debit_amount,
        el.credit_amount
    FROM entry_lines el
    JOIN journal_entries je
      ON je.entry_id = el.entry_id
     AND je.status = 'posted'
    JOIN documents d ON d.document_id = je.document_id
    JOIN personal_accounts pa ON pa.account_id = el.account_id
    WHERE pa.account_number = :'acc'
      AND je.entry_date <= :'date_to'::date
),
calc AS (
    SELECT
        s.*,
        SUM(COALESCE(s.debit_amount, 0) - COALESCE(s.credit_amount, 0))
            OVER (ORDER BY s.entry_date, s.document_id
                  ROWS UNBOUNDED PRECEDING) AS running_signed
    FROM scope s
),
lines AS (
    SELECT
        entry_date,
        document_id::text AS ref,
        doc_type,
        description,
        debit_amount,
        credit_amount,
        running_signed
    FROM calc
    WHERE entry_date >= :'date_from'::date
),
opening AS (
    -- Одна строка: входящее сальдо по всем движениям ДО начала периода.
    SELECT
        NULL::date AS entry_date,
        '-'::text  AS ref,
        '-'::text  AS doc_type,
        'Входящее сальдо на начало периода'::text AS description,
        NULL::numeric AS debit_amount,
        NULL::numeric AS credit_amount,
        SUM(COALESCE(s.debit_amount, 0) - COALESCE(s.credit_amount, 0)) AS running_signed
    FROM scope s
    WHERE s.entry_date < :'date_from'::date
)
SELECT
    entry_date,
    ref,
    doc_type,
    description,
    debit_amount,
    credit_amount,
    GREATEST(running_signed, 0)  AS balance_debit,
    GREATEST(-running_signed, 0) AS balance_credit
FROM (
    SELECT * FROM opening
    UNION ALL
    SELECT * FROM lines
) t
ORDER BY entry_date NULLS FIRST, ref;
