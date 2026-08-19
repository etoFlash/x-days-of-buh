-- ============================================================================
-- osv.sql — оборотно-сальдовая ведомость (ОСВ) за период
-- ============================================================================
-- Классическая форма: сальдо входящее → обороты за период → сальдо исходящее,
-- всё свёрнуто до синтетических счетов плана счетов.
--
-- Запуск из psql:
--   psql ... -v date_from='2026-01-05' -v date_to='2026-01-07' -f db/queries/osv.sql
-- ============================================================================

\echo ''
\echo '=== ОСВ за период' :date_from '—' :date_to '==='

WITH lines_in_scope AS (
    SELECT
        el.account_id,
        je.entry_date,
        el.debit_amount,
        el.credit_amount
    FROM entry_lines el
    JOIN journal_entries je
      ON je.entry_id = el.entry_id
     AND je.status = 'posted'
    WHERE je.entry_date <= :'date_to'::date
),
by_account AS (
    SELECT
        pa.coa_number,
        -- входящее сальдо на начало периода (дт+ / кт−, в валюте учёта RUB)
        SUM(CASE WHEN s.entry_date < :'date_from'::date
                 THEN COALESCE(s.debit_amount, 0) - COALESCE(s.credit_amount, 0)
                 ELSE 0 END)            AS opening_signed,
        -- обороты за период
        SUM(CASE WHEN s.entry_date >= :'date_from'::date
                 THEN COALESCE(s.debit_amount, 0) ELSE 0 END)  AS turnover_debit,
        SUM(CASE WHEN s.entry_date >= :'date_from'::date
                 THEN COALESCE(s.credit_amount, 0) ELSE 0 END) AS turnover_credit
    FROM lines_in_scope s
    JOIN personal_accounts pa ON pa.account_id = s.account_id
    GROUP BY pa.coa_number
)
SELECT
    b.coa_number,
    coa.account_name,
    GREATEST(b.opening_signed, 0)  AS opening_debit,
    GREATEST(-b.opening_signed, 0) AS opening_credit,
    b.turnover_debit,
    b.turnover_credit,
    GREATEST(b.opening_signed + b.turnover_debit - b.turnover_credit, 0)  AS closing_debit,
    GREATEST(-(b.opening_signed + b.turnover_debit - b.turnover_credit), 0) AS closing_credit
FROM by_account b
JOIN chart_of_accounts coa ON coa.account_number = b.coa_number
ORDER BY b.coa_number;
